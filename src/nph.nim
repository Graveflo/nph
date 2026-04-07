#           nph
#        (c) Copyright 2023 Jacek Sieka
## Opinionated source code formatter

import
  std/[parseopt, strutils, os, sequtils, tables, terminal, options],
  ./hldiffpkg/edits,
  ./[
    astcmp, astyaml, phast, phastyaml, phmsgs, phlineinfos, phoptions, phparser,
    phrenderer,
  ],
  regex,
  "$nim"/compiler/idents

when defined(nimPreviewSlimSystem):
  import std/[assertions, syncio]

const
  Version = gorge("git describe --long --dirty --always --tags")
  Usage =
    "nph - Nim formatter " & Version & """
Usage:
  nph [options] nimfiles...

Options:
  --check               check the formatting instead of performing it
  --diff                show diff of formatting changes without writing files
  --out:file            set the output file (default: overwrite the input file)
  --color               force colored diff output (only applies when --diff is given)
  --no-color            disable colored diff output
  --version             show the version
  --help                show this help

"""
  DefaultIncludePattern = r"\.nim(s|ble)?$"
  ErrCheckFailed = 1
  ErrDiffChanges = 2 # --diff mode: changes found (but exit 0)
  ErrParseInputFailed = 3
  ErrParseOutputFailed = 4
  ErrEqFailed = 5

proc writeHelp() =
  stdout.write(Usage)
  stdout.flushFile()
  quit(0)

proc writeVersion() =
  stdout.write(Version & "\n")
  stdout.flushFile()
  quit(0)

proc parse(input, filename: string, printTokens: bool, conf: ConfigRef): PNode =
  let fn = if filename == "-": "stdin" else: filename

  parseString(input, newIdentCache(), conf, fn, printTokens = printTokens)

proc makeConfigRef(): ConfigRef =
  let conf = newConfigRef()
  conf.errorMax = int.high
  conf

func normalizePath(path: string): string =
  ## Normalize path to use forward slashes for cross-platform regex matching
  ## Following Black's approach: convert all backslashes to forward slashes
  path.replace("\\", "/")


proc printDiff(input, output, infile: string, color: bool) =
  ## Print unified diff between input and output
  let
    inputLines = input.split('\n')
    outputLines = output.split('\n')
    sm = sames(inputLines, outputLines)

  var begun = false
  for eds in grouped(sm, 3):
    if not begun:
      begun = true
      if color:
        stdout.styledWriteLine(styleBright, "--- " & infile)
        stdout.styledWriteLine(styleBright, "+++ " & infile & " (formatted)")
      else:
        stdout.writeLine("--- " & infile)
        stdout.writeLine("+++ " & infile & " (formatted)")

    let marker =
      "@@ -" & rangeUni(eds[0].s.a, eds[^1].s.b + 1) & " +" &
      rangeUni(eds[0].t.a, eds[^1].t.b + 1) & " @@"

    if color:
      stdout.styledWriteLine(fgCyan, marker)
    else:
      stdout.writeLine(marker)

    for ed in eds:
      case ed.ek
      of ekEql:
        for ln in inputLines[ed.s]:
          stdout.writeLine(" " & ln)
      of ekDel:
        for ln in inputLines[ed.s]:
          if color:
            stdout.styledWriteLine(fgRed, "-" & ln)
          else:
            stdout.writeLine("-" & ln)
      of ekIns:
        for ln in outputLines[ed.t]:
          if color:
            stdout.styledWriteLine(fgGreen, "+" & ln)
          else:
            stdout.writeLine("+" & ln)
      of ekSub:
        for ln in inputLines[ed.s]:
          if color:
            stdout.styledWriteLine(fgRed, "-" & ln)
          else:
            stdout.writeLine("-" & ln)
        for ln in outputLines[ed.t]:
          if color:
            stdout.styledWriteLine(fgGreen, "+" & ln)
          else:
            stdout.writeLine("+" & ln)

proc prettyPrint(
    infile, outfile: string, debug, check, diff, printTokens, color: bool
): int =
  let
    conf = makeConfigRef()
    input =
      if infile == "-":
        readAll(stdin)
      else:
        readFile(infile)
    node = parse(input, infile, printTokens, conf)

  if conf.errorCounter > 0:
    localError(
      conf, TLineInfo(fileIndex: FileIndex(0)), "Skipped file, input cannot be parsed"
    )

    return ErrParseInputFailed

  var output = renderTree(node, conf)
  if not output.endsWith("\n"):
    output.add "\n"

  if conf.errorCounter > 0:
    return ErrParseOutputFailed

  # Handle --diff mode: print diff and exit early
  if diff:
    if input != output:
      printDiff(input, output, infile, color)
      # --diff alone is informational (exit 0), --diff --check fails (exit 1)
      return if check: ErrCheckFailed else: ErrDiffChanges
    else:
      return QuitSuccess # No changes needed

  if infile != "-":
    if debug:
      # Always write file in debug mode
      writeFile(infile & ".nph.yaml", treeToYaml(nil, node) & "\n")
      if infile != outfile:
        writeFile(outfile, output)
        writeFile(
          outfile & ".nph.yaml",
          treeToYaml(nil, parse(output, outfile, printTokens, newConfigRef())) & "\n",
        )
    elif fileExists(outfile) and output == readFile(outfile):
      # No formatting difference - don't touch file modificuation date
      return QuitSuccess

  let eq = equivalent(input, infile, output, if infile == "-": "stdout" else: outfile)

  template writeUnformatted() =
    if not debug and (infile != outfile or infile == "-"):
      # Write unformatted content
      if not check:
        if infile == "-":
          write(stdout, input)
        else:
          writeFile(outfile, input)

  case eq.kind
  of Same:
    if check:
      # Print which file would be reformatted (like Black)
      if input != output:
        stderr.writeLine("would reformat " & infile)
      ErrCheckFailed # We failed the equivalence check above
    else:
      # Formatting changed the file
      if not debug or infile == "-":
        if infile == "-":
          write(stdout, output)
        else:
          writeFile(outfile, output)

      QuitSuccess
  of ParseError:
    writeUnformatted()

    localError(
      conf,
      TLineInfo(fileIndex: FileIndex(0)),
      "Skipped file, formatted output cannot be parsed (bug! " & Version & ")",
    )

    ErrEqFailed
  of Different:
    writeUnformatted()

    stderr.writeLine "--- Input ---"
    stderr.writeLine input
    stderr.writeLine "--- Formatted ---"
    stderr.writeLine output
    stderr.writeLine "--- PRE ---"
    stderr.writeLine treeToYaml(nil, eq.a)
    stderr.writeLine "--- POST ---"
    stderr.writeLine treeToYaml(nil, eq.b)

    localError(
      conf,
      TLineInfo(fileIndex: FileIndex(0)),
      "Skipped file, formatted output does not match input (bug! " & Version & ")",
    )

    ErrEqFailed

proc main() =
  var
    outfile, outdir, configFile, infile: string
    debug = false
    check = false
    diff = false
    printTokens = false
    cliColorSet = false
    # Default to color if stdout is a TTY and NO_COLOR is not set or empty
    cliColor = getEnv("NO_COLOR") == "" and isatty(stdout)

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      infile = key
    of cmdLongOption, cmdShortOption:
      case normalize(key)
      of "help", "h":
        writeHelp()
      of "version", "v":
        writeVersion()
      of "debug":
        debug = true
      of "print-tokens":
        printTokens = true
      of "check":
        check = true
      of "diff":
        diff = true
      of "output", "o", "out":
        outfile = val
      of "outDir", "outdir":
        outdir = val
      of "color":
        cliColorSet = true
        cliColor = true
      of "no-color", "nocolor":
        cliColorSet = true
        cliColor = false
      of "config":
        configFile = val
      of "":
        infile = "-"
      else:
        writeHelp()
    of cmdEnd:
      assert(false) # cannot happen
  if outfile.len == 0:
    outfile = infile
  quit prettyPrint(infile, outfile, debug, check, diff, printTokens, cliColor)

when isMainModule:
  main()
