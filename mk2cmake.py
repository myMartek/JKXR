#!/usr/bin/env python3
"""Übersetzt JKXRs Android-Makefiles nach CMake für visionOS.

JKXR wird für Android mit ndk-build gebaut; Quelldateilisten, Include-Pfade und
Compilerflags stehen in `Android.mk`-Dateien. Für visionOS gibt es keinen
entsprechenden Build. Die Listen von Hand abzutippen wäre fehleranfällig — die
Engine allein hat 455 Quelldateien — und liefe bei jedem JKXR-Update auseinander.

Unterstützt wird nur so viel ndk-build-Syntax, wie in diesen Dateien vorkommt:
Variablenzuweisungen mit `:=`, `+=` und `=`, Zeilenfortsetzungen, und
Variablenersetzung `$(NAME)` / `${NAME}`.

Aufruf:

    python3 mk2cmake.py <modul-verzeichnis> <ausgabe.cmake> [--mk DATEI]
                        [--context DATEI]...

    --mk        Makefile im Modulverzeichnis (Vorgabe: Android.mk)
    --context   Makefile, aus der globale Variablen übernommen werden
                (etwa Application.mk mit TOP_DIR, OPENJK_PATH, JK3_CODE_PATH)
"""

import argparse
import re
import sys
from pathlib import Path

ASSIGN = re.compile(r"^\s*([A-Za-z_][A-Za-z_0-9]*)\s*([:+?]?=)\s*(.*)$")
REFERENCE = re.compile(r"\$[({]([A-Za-z_][A-Za-z_0-9]*)[)}]")

SOURCE_SUFFIXES = (".c", ".cpp", ".cc", ".S")
FLAG_PREFIXES = ("-D", "-f", "-W", "-O", "-std", "-m")


def parse(path: Path) -> dict[str, list[str]]:
    """Liest die Variablenzuweisungen einer Makefile, Fortsetzungen aufgelöst."""
    variables: dict[str, list[str]] = {}
    pending: str | None = None

    # $(call my-dir) liefert in ndk-build das Verzeichnis der Makefile. Die
    # Ersetzung muss vor dem Zerlegen passieren: der Ausdruck enthält ein
    # Leerzeichen und würde sonst in zwei Tokens zerrissen.
    text = path.read_text(errors="surrogateescape")
    text = text.replace("$(call my-dir)", str(path.parent.resolve()))

    for raw in text.splitlines():
        line = raw.split("#", 1)[0]
        continues = line.rstrip().endswith("\\")
        line = line.rstrip().rstrip("\\").strip()

        if pending is not None:
            variables[pending].extend(line.split())
            if not continues:
                pending = None
            continue

        match = ASSIGN.match(line)
        if not match:
            continue
        name, operator, value = match.groups()
        if operator == "+=":
            variables.setdefault(name, []).extend(value.split())
        else:
            variables[name] = value.split()
        if continues:
            pending = name

    return variables


def resolve(token: str, variables: dict[str, list[str]], depth: int = 0) -> str | None:
    """Ersetzt $(NAME) rekursiv. Gibt None zurück, wenn etwas offen bleibt.

    Bewusst None statt eines halb ersetzten Tokens: ein unaufgelöster
    Include-Pfad, der stillschweigend durchrutscht, äußert sich später als
    scheinbar unerklärliches "Header nicht gefunden".
    """
    if depth > 10:
        return None

    def substitute(match: re.Match) -> str:
        value = variables.get(match.group(1))
        return " ".join(value) if value is not None else match.group(0)

    replaced = REFERENCE.sub(substitute, token)
    if replaced == token:
        return None if REFERENCE.search(replaced) else replaced
    return resolve(replaced, variables, depth + 1)


def resolve_all(tokens: list[str], variables: dict[str, list[str]],
                what: str) -> list[str]:
    result = []
    for token in tokens:
        value = resolve(token, variables)
        if value is None:
            print(f"  WARNUNG {what}: unaufgelöste Variable verworfen: {token}")
            continue
        result.extend(value.split())
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--mk", default="Android.mk")
    parser.add_argument("--context", type=Path, action="append", default=[])
    parser.add_argument("--exclude", action="append", default=[],
                        help="Quellen verwerfen, deren Pfad diesen Text enthält "
                             "(etwa plattformspezifische Verzeichnisse)")
    args = parser.parse_args()

    makefile = args.directory / args.mk
    if not makefile.is_file():
        print(f"FEHLER: {makefile} nicht gefunden")
        return 1

    # Globaler Variablenkontext, dann die Modul-Makefile darüber.
    variables: dict[str, list[str]] = {}
    for context in args.context:
        if not context.is_file():
            print(f"FEHLER: Kontextdatei {context} nicht gefunden")
            return 1
        variables.update(parse(context))
    variables.update(parse(makefile))

    # LOCAL_PATH ist die Basis der Quellpfade. Meist das Verzeichnis der
    # Makefile, kann aber abweichen — sigc++ setzt "$(call my-dir)/../", die
    # Quellen liegen dort eine Ebene höher. Da $(call my-dir) beim Einlesen
    # bereits durch einen absoluten Pfad ersetzt wurde, genügt es, den Wert zu
    # übernehmen.
    base = args.directory
    local_path = " ".join(variables.get("LOCAL_PATH", []))
    if local_path:
        candidate = resolve(local_path, variables)
        if candidate and Path(candidate).is_dir():
            base = Path(candidate).resolve()

    module = variables.get("LOCAL_MODULE", ["unnamed"])[0]

    sources = [s for s in resolve_all(variables.get("LOCAL_SRC_FILES", []),
                                      variables, module)
               if s.endswith(SOURCE_SUFFIXES)]

    if args.exclude:
        before = len(sources)
        sources = [s for s in sources
                   if not any(pattern in s for pattern in args.exclude)]
        if before != len(sources):
            print(f"  {before - len(sources)} Quelle(n) ausgeschlossen "
                  f"({', '.join(args.exclude)})")
    if not sources:
        print(f"  FEHLER  {module}: keine Quelldateien in {makefile}")
        return 1

    resolved: list[Path] = []
    missing: list[str] = []
    for source in sources:
        candidate = Path(source)
        if not candidate.is_absolute():
            candidate = base / source
        if candidate.is_file():
            resolved.append(candidate.resolve())
        else:
            missing.append(source)

    if missing:
        print(f"  WARNUNG {module}: {len(missing)} Quelle(n) nicht gefunden, "
              f"z. B. {missing[0]}")
    if not resolved:
        print(f"  FEHLER  {module}: keine der Quellen existiert (Basis {base})")
        return 1

    includes = []
    for include in resolve_all(variables.get("LOCAL_C_INCLUDES", []),
                               variables, module):
        path = Path(include)
        if not path.is_absolute():
            path = base / include
        includes.append(path.resolve())

    cflags = [f for f in resolve_all(variables.get("LOCAL_CFLAGS", []),
                                     variables, module)
              if f.startswith(FLAG_PREFIXES)]
    cppflags = [f for f in resolve_all(variables.get("LOCAL_CPPFLAGS", []),
                                       variables, module)
                if f.startswith(FLAG_PREFIXES)]

    lines = [
        f"# Erzeugt aus {makefile.name} von mk2cmake.py — nicht von Hand ändern.",
        f"# Modul: {module}, {len(resolved)} Quelldateien",
        "",
        f"add_library({module} STATIC",
    ]
    lines += [f"    {p}" for p in sorted(set(resolved))]
    lines.append(")")
    lines.append("")
    lines.append(f"target_include_directories({module} PUBLIC")
    lines.append(f"    {base.resolve()}")
    lines += [f"    {p}" for p in dict.fromkeys(includes)]
    lines.append(")")

    if cflags or cppflags:
        lines.append("")
        lines.append(f"target_compile_options({module} PRIVATE")
        # LOCAL_CFLAGS gilt in ndk-build für C *und* C++; nur LOCAL_CPPFLAGS
        # ist C++-exklusiv. Beschränkt man CFLAGS auf C, fehlen Definitionen
        # wie -DHAVE_GLES ausgerechnet in den C++-Dateien — und die Header
        # nehmen dann stillschweigend einen anderen Zweig.
        lines += [f"    {f}" for f in dict.fromkeys(cflags)]
        lines += [f"    $<$<COMPILE_LANGUAGE:CXX>:{f}>"
                  for f in dict.fromkeys(cppflags)]
        lines.append(")")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n")
    print(f"  ok      {module}: {len(resolved)} Quellen -> {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
