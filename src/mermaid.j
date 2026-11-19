# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: exec

/**
 * Mermaid diagrams for Grimoire, drawn while the book is built.
 *
 * A preprocessor. Every `mermaid` fence in a chapter is rendered by an external
 * program, `merman-cli` by default or `mmdr`, and replaced by a paragraph that
 * holds only the picture:
 *
 *     ```mermaid                       ![Build flow](_generated/mermaid/3f9c2a7d01b4e6c8.svg)
 *     flowchart LR
 *       accTitle: Build flow
 *       A --> B
 *     ```
 *
 * The files go into the directory Grimoire hands a preprocessor as
 * `plugin.files`, which it treats as `_generated/NAME/` under the book: the
 * site copies them, the EPUB carries the SVG in, and the printable book draws
 * the PNG written beside it.
 *
 * The contract, the fences, the names and the concurrency come from Grimoire's
 * plugin kit; what is here is Mermaid's: the settings, the alt text, and the two
 * renderers' command lines.
 * @module mermaid
 * @author mplx <mplx@jennifer-lang.dev>
 * @license LGPL-3.0-only
 */
use io;
use fs;
use path;
use json;
use strings;
use lists;
use maps;
use convert;
use regex;
use hash;
use encoding;
use math;

import "./pluginkit.j" as kit;

# Caps, in bytes. A diagram is a few hundred bytes of text, and a picture of
# one a few hundred kilobytes; anything far beyond either is a mistake or an
# attack, and it throws "limit" rather than filling a disk.
def const MAX_SOURCE as int init 262144;
def const MAX_OUTPUT as int init 16777216;

# The largest PNG scale accepted. A scale is a multiplier on a diagram's own
# size, and the PDF only needs enough pixels for print.
def const MAX_SCALE as int init 8;

# How many hex digits of the hash name a file: 64 bits.
def const NAME_DIGITS as int init 16;

# What the settings may say, beside Grimoire's own `command` and `args`.
def const SETTINGS as list of string init [
    "renderer",
    "program",
    "theme",
    "font",
    "png",
    "scale",
    "jobs"
];
def const RENDERERS as list of string init ["merman", "mmdr"];

# The face the printable book uses, so the PNG's text is measured and drawn in
# the font around it. `fc-match` turns it into a file.
def const DEFAULT_FACE as string init "DejaVu Sans";

# The ASCII punctuation that means something inside an image's alt text: emphasis,
# code, raw HTML, an entity, and Grimoire's mark / sub / sup extensions. Brackets
# are replaced instead of escaped, because the printable book reads an image
# with a pattern that stops at the first `]`.
def const ALT_ESCAPED as list of string init ["\\", "`", "*", "_", "<", ">", "&", "~", "=", "^"];

# --- settings ---------------------------------------------------------

/**
 * What the `[preprocessor.mermaid]` table says, checked and with defaults.
 * @field renderer {string} "merman" or "mmdr"
 * @field program {string} the renderer's command: a name on PATH or a path
 * @field theme {string} the theme handed to the renderer
 * @field font {string} a font file (merman only); "" until resolved
 * @field png {bool} also write a PNG for the printable book
 * @field scale {float} the PNG's size against the diagram's own
 * @field jobs {int} renders at a time; 0 is one per CPU
 */
export def struct Settings {
    renderer as string,
    program as string,
    theme as string,
    font as string,
    png as bool,
    scale as float,
    jobs as int
};

/**
 * Read the settings from a request.
 *
 * Every key is checked: an unknown one is a typo or a setting of another plugin,
 * and building without it would draw the book some way nobody asked for.
 * @param req {json.Value} the decoded request
 * @return {Settings} the settings, with defaults filled in
 * @throws {Error} kind "plugin" for an unknown key or a value of the wrong kind
 */
export func settingsOf(req as json.Value) {
    kit.checkSettings($req, SETTINGS);
    def s as Settings init Settings{
        renderer: kit.settingText($req, "renderer", "merman"),
        program: kit.settingText($req, "program", ""),
        theme: kit.settingText($req, "theme", "neutral"),
        font: kit.settingText($req, "font", ""),
        png: kit.settingBool($req, "png", true),
        scale: kit.settingNumber($req, "scale", 2.0),
        jobs: kit.settingInt($req, "jobs", 0)
    };
    if (not lists.contains(RENDERERS, $s.renderer)) {
        kit.fail("setting `renderer` is \"" + $s.renderer + "\"; it takes \"merman\" or \"mmdr\"");
    }
    if ($s.program == "") {
        $s.program = "merman-cli";
        if ($s.renderer == "mmdr") {
            $s.program = "mmdr";
        }
    }
    if ($s.theme == "") {
        kit.fail("setting `theme` is empty");
    }
    if ($s.font != "" and $s.renderer == "mmdr") {
        kit.fail("setting `font` is for merman; mmdr takes no font file");
    }
    if ($s.scale <= 0.0 or $s.scale > convert.toFloat(MAX_SCALE)) {
        kit.fail("setting `scale` must be above 0 and at most " + convert.toString(MAX_SCALE));
    }
    if ($s.jobs < 0) {
        kit.fail("setting `jobs` must be 0 or more");
    }
    return $s;
}

# scaleText is the scale as the command line and the hash spell it: `2` rather
# than `2.0`, so the common case reads the way it was written.
func scaleText(scale as float) {
    if ($scale == convert.toFloat(math.trunc($scale))) {
        return convert.toString(math.trunc($scale));
    }
    return convert.toString($scale);
}

# --- fences -----------------------------------------------------------

/**
 * One `mermaid` fence in a chapter.
 * @field chapter {string} the chapter's `src`
 * @field line {int} the opening fence's line, from 1
 * @field first {int} the index of the opening fence's line
 * @field last {int} the index of the closing fence's line
 * @field indent {string} the opening fence's indentation, as written
 * @field source {string} the diagram, with the fence's indentation removed
 * @field alt {string} the alt text: the diagram's `accTitle`, or "Diagram"
 */
export def struct Diagram {
    chapter as string,
    line as int,
    first as int,
    last as int,
    indent as string,
    source as string,
    alt as string
};

/**
 * The alt text for a diagram: its accessibility title, or "Diagram".
 *
 * Mermaid's `accTitle:` is what a screen reader announces for the diagram, so
 * it is the right text wherever the picture cannot be seen, and the printable
 * book prints it when a picture is missing.
 * @param source {string} the diagram
 * @return {string} the alt text, unescaped
 */
export func altOf(source as string) {
    for (def line in strings.split($source, "\n")) {
        def m as regex.Match init regex.find('^\s*accTitle\s*:\s*(.*?)\s*$', $line);
        if ($m.start >= 0 and $m.groups[0] != "") {
            return $m.groups[0];
        }
    }
    return "Diagram";
}

# altMarkdown makes alt text safe inside `![...]`.
func altMarkdown(alt as string) {
    def out as string init strings.replace(strings.replace($alt, "[", "("), "]", ")");
    for (def ch in ALT_ESCAPED) {
        $out = strings.replace($out, $ch, "\\" + $ch);
    }
    return $out;
}

/**
 * Find every `mermaid` fence in a chapter.
 *
 * The fences are the kit's CommonMark ones; a fence is a diagram when its info
 * string's first word is `mermaid`, exactly.
 * @param chapter {string} the chapter's `src`, for errors
 * @param content {string} the chapter's Markdown
 * @return {list of Diagram} the diagrams, in order
 * @throws {Error} kind "plugin" for a `mermaid` fence that is never closed;
 *   kind "limit" for a diagram over the source cap
 */
export func diagramsIn(chapter as string, content as string) {
    def out as list of Diagram;
    for (def f in kit.fencesIn($content)) {
        if (kit.languageOf($f.info) != "mermaid") {
            continue;
        }
        if (not $f.closed) {
            kit.failAt("plugin", $chapter, $f.first + 1, "the mermaid fence is never closed");
        }
        def source as string init $f.body;
        if ($source == "") {
            $source = "\n";
        }
        if (encoding.lenBytes($source) > MAX_SOURCE) {
            kit.failAt(
                "limit",
                $chapter,
                $f.first + 1,
                "the diagram is over " + convert.toString(MAX_SOURCE) + " bytes");
        }
        $out[] = Diagram{
            chapter: $chapter,
            line: $f.first + 1,
            first: $f.first,
            last: $f.last,
            indent: $f.indent,
            source: $source,
            alt: altOf($source)
        };
    }
    return $out;
}

/**
 * Replace each fence with a paragraph holding only its picture.
 *
 * A blank line is put on either side where the chapter has none, so the image
 * neither joins the paragraph above nor takes in the one below. The fence's own
 * indentation is kept, which keeps a fence inside a list item in the item.
 * @param content {string} the chapter's Markdown
 * @param diagrams {list of Diagram} what `diagramsIn` found in it
 * @param targets {list of string} each diagram's image path, in the same order
 * @return {string} the rewritten chapter
 */
export func rewrite(content as string, diagrams as list of Diagram, targets as list of string) {
    def lines as list of string init strings.split($content, "\n");
    def out as list of string;
    def i as int init 0;
    def f as int init 0;
    while ($i < len($lines)) {
        if ($f >= len($diagrams) or $i != $diagrams[$f].first) {
            $out[] = $lines[$i];
            $i = $i + 1;
            continue;
        }
        def d as Diagram init $diagrams[$f];
        if (len($out) > 0 and strings.trim($out[len($out) - 1]) != "") {
            $out[] = "";
        }
        $out[] = $d.indent + "![" + altMarkdown($d.alt) + "](" + $targets[$f] + ")";
        $i = $d.last + 1;
        if ($i < len($lines) and strings.trim($lines[$i]) != "") {
            $out[] = "";
        }
        $f = $f + 1;
    }
    return strings.join($out, "\n");
}

# --- the renderer -----------------------------------------------------

/**
 * The renderer as one build uses it: the settings, and what was found out
 * about the program and the font.
 * @field settings {Settings} the checked settings, `font` resolved for merman
 * @field version {string} what `--version` printed
 * @field fontDigest {string} the font file's sha256, "" for mmdr
 */
export def struct Renderer {
    settings as Settings,
    version as string,
    fontDigest as string
};

# missing says what to do about a renderer that cannot be run.
func missing(s as Settings, why as string) {
    def name as string init "merman-cli";
    if ($s.renderer == "mmdr") {
        $name = "mmdr";
    }
    kit.fail(kit.missingProgram($s.program, $why, $name, "program"));
}

# versionOf asks the renderer what it is. Its answer goes into every name, so a
# new renderer release redraws the book rather than mixing old pictures with new.
func versionOf(s as Settings) {
    def ran as kit.Ran init kit.runProgram([$s.program, "--version"], "");
    if (not $ran.started) {
        missing($s, $ran.message);
    }
    if ($ran.exitCode != 0) {
        missing($s, "--version exited " + convert.toString($ran.exitCode));
    }
    def line as string init kit.firstLine($ran.stdout);
    if ($line == "") {
        missing($s, "--version printed nothing");
    }
    return $line;
}

# fontFile is the font merman measures and draws text with: the setting, or the
# file fontconfig names for the face the printable book uses.
func fontFile(s as Settings) {
    if ($s.font != "") {
        if (not fs.isFile($s.font)) {
            kit.fail("font file not found: " + $s.font);
        }
        return $s.font;
    }
    def ran as kit.Ran init kit.runProgram(["fc-match", "-f", '%{file}', DEFAULT_FACE], "");
    if (not $ran.started) {
        kit.fail("cannot run fc-match to find " + DEFAULT_FACE + " (" + $ran.message +
            "); set `font` to a font file");
    }
    def file as string init strings.trim($ran.stdout);
    if ($ran.exitCode != 0 or not fs.isFile($file)) {
        kit.fail("fc-match found no file for " + DEFAULT_FACE + "; set `font` to a font file");
    }
    return $file;
}

/**
 * Find the renderer and the font, once per build.
 * @param s {Settings} the checked settings
 * @return {Renderer} the settings with the font resolved, and the version
 * @throws {Error} kind "plugin" when the program or the font is missing
 */
export func rendererFor(s as Settings) {
    def out as Renderer init Renderer{settings: $s, version: versionOf($s), fontDigest: ""};
    if ($s.renderer == "merman") {
        $out.settings.font = fontFile($s);
        $out.fontDigest = encoding.toText(
            "hex",
            hash.compute("sha256", fs.readBytes($out.settings.font)));
    }
    return $out;
}

/**
 * The file name a diagram is drawn under, without its extension.
 *
 * Everything that changes the picture is in it, and nothing else: the program's
 * path and `jobs` are left out, so moving the renderer or building faster
 * draws nothing new. The font is in it by content, not by path, so two machines
 * with the same font give the same names.
 * @param r {Renderer} the renderer
 * @param source {string} the diagram
 * @return {string} hex digits
 */
export func nameOf(r as Renderer, source as string) {
    def png as string init "svg";
    if ($r.settings.png) {
        $png = "svg+png";
    }
    return kit.contentName(
        [
            "grimoire-mermaid 1",
            $r.settings.renderer,
            $r.version,
            $r.settings.theme,
            $r.fontDigest,
            $png,
            scaleText($r.settings.scale),
            $source
        ],
        NAME_DIGITS);
}

# svgArgs is the command line that writes a diagram's SVG.
#
# merman's default SVG keeps the labels as HTML in `<foreignObject>`, which many
# EPUB readers do not draw; `resvg-safe` turns them into SVG text. The font is
# passed for the SVG too, so its layout matches the PNG's.
func svgArgs(s as Settings, target as string) {
    if ($s.renderer == "mmdr") {
        return [$s.program, "-i", "-", "-o", $target, "-e", "svg", "-t", $s.theme];
    }
    return [
        $s.program,
        "render",
        "-",
        "-o",
        $target,
        "-f",
        "svg",
        "--svg-pipeline",
        "resvg-safe",
        "-t",
        $s.theme,
        "--font-file",
        $s.font,
        "-q"
    ];
}

# pngArgs is the command line that writes a diagram's PNG. `size` is mmdr's
# pixel size; merman scales by itself.
#
# merman needs a font file for a PNG: without one it scans every system font
# and fails on a machine with many ("native font limit ... exceeded").
func pngArgs(s as Settings, target as string, size as list of int) {
    if ($s.renderer == "mmdr") {
        return [
            $s.program,
            "-i",
            "-",
            "-o",
            $target,
            "-e",
            "png",
            "-t",
            $s.theme,
            "-w",
            convert.toString($size[0]),
            "-H",
            convert.toString($size[1])
        ];
    }
    return [
        $s.program,
        "render",
        "-",
        "-o",
        $target,
        "-f",
        "png",
        "-s",
        scaleText($s.scale),
        "-t",
        $s.theme,
        "--font-file",
        $s.font,
        "-q"
    ];
}

# numberAt reads a JSON number that may be written either way.
func numberAt(doc as json.Value, ptr as string) {
    if (json.typeOf($doc, $ptr) == "int") {
        return convert.toFloat(json.asInt($doc, $ptr));
    }
    return json.asFloat($doc, $ptr);
}

# --- drawing ----------------------------------------------------------

# The settings as the drawing tasks get them: a JSON context, because the kit's
# workers take one, and the directory the files go into.
func contextOf(s as Settings, dir as string) {
    return json.decode('{"renderer":' + json.encode($s.renderer) +
        ',"program":' + json.encode($s.program) +
        ',"theme":' + json.encode($s.theme) +
        ',"font":' + json.encode($s.font) +
        ',"png":' + json.encode($s.png) +
        ',"scale":' + json.encode($s.scale) +
        ',"dir":' + json.encode($dir) + '}');
}

func settingsFrom(ctx as json.Value) {
    return Settings{
        renderer: json.asString($ctx, "/renderer"),
        program: json.asString($ctx, "/program"),
        theme: json.asString($ctx, "/theme"),
        font: json.asString($ctx, "/font"),
        png: json.asBool($ctx, "/png"),
        scale: numberAt($ctx, "/scale"),
        jobs: 0
    };
}

# refused reports a render that failed, at the first fence that asked for it.
func refused(item as json.Value, program as string, message as string) {
    kit.failAt(
        "plugin",
        json.asString($item, "/chapter"),
        json.asInt($item, "/line"),
        $program + ": " + $message);
}

# checked refuses a file the renderer says it wrote but that is missing or over
# the cap.
func checked(item as json.Value, program as string, target as string) {
    if (not fs.isFile($target)) {
        refused($item, $program, "wrote no " + path.base($target));
    }
    if (fs.stat($target).size > MAX_OUTPUT) {
        kit.failAt(
            "limit",
            json.asString($item, "/chapter"),
            json.asInt($item, "/line"),
            $program + ": " + path.base($target) + " is over " + convert.toString(MAX_OUTPUT) +
                " bytes");
    }
}

# mmdrSize is the pixel size of mmdr's PNG: the diagram's own size, which
# `--size` reports, times the scale. mmdr has no scale of its own.
func mmdrSize(s as Settings, item as json.Value, source as string) {
    def ran as kit.Ran init kit.runProgram(
        [$s.program, "-i", "-", "--size", "-t", $s.theme],
        $source);
    if ($ran.message != "") {
        refused($item, $s.program, $ran.message);
    }
    def doc as json.Value init json.decode($ran.stdout);
    return [
        math.ceil(numberAt($doc, "/width") * $s.scale),
        math.ceil(numberAt($doc, "/height") * $s.scale)
    ];
}

/**
 * Draw one diagram's files: the kit's worker, run concurrently.
 * @param ctx {json.Value} the settings and the directory, from `contextOf`
 * @param item {json.Value} `name`, `source`, and the `chapter` and `line` of
 *   the first fence that asked for it
 * @return {string} ""
 * @throws {Error} kind "plugin" for a refused diagram, "limit" over a cap
 */
export func drawItem(ctx as json.Value, item as json.Value) {
    def s as Settings init settingsFrom($ctx);
    def dir as string init json.asString($ctx, "/dir");
    def name as string init json.asString($item, "/name");
    def source as string init json.asString($item, "/source");
    def svg as string init path.join($dir, $name + ".svg");
    def ran as kit.Ran init kit.runProgram(svgArgs($s, $svg), $source);
    if ($ran.message != "") {
        refused($item, $s.program, $ran.message);
    }
    checked($item, $s.program, $svg);
    if (not $s.png) {
        return "";
    }
    def png as string init path.join($dir, $name + ".png");
    def size as list of int init [0, 0];
    if ($s.renderer == "mmdr") {
        $size = mmdrSize($s, $item, $source);
    }
    $ran = kit.runProgram(pngArgs($s, $png, $size), $source);
    if ($ran.message != "") {
        refused($item, $s.program, $ran.message);
    }
    checked($item, $s.program, $png);
    return "";
}

# --- the request ------------------------------------------------------

/**
 * Answer one request: draw every diagram and rewrite the chapters that had any.
 * @param req {json.Value} the decoded request, checked by `kit.request`
 * @return {string} the reply, as JSON
 * @throws {Error} kind "plugin" for a request without `files`, a bad setting, a
 *   missing renderer or a diagram the renderer refused; kind "limit" over a cap
 */
export func replyFor(req as json.Value) {
    def dir as string init kit.requireFiles($req);
    def s as Settings init settingsOf($req);
    def plugin as string init json.asString($req, "/plugin/name");
    # Every fence first, so a fence error stops the build before anything runs.
    def chapters as list of string;
    def contents as list of string;
    def found as list of list of Diagram;
    def total as int init 0;
    for (def i in 0..json.length($req, "/chapters")) {
        def at as string init "/chapters/" + convert.toString($i);
        def src as string init json.asString($req, $at + "/src");
        def content as string init json.asString($req, $at + "/content");
        def diagrams as list of Diagram init diagramsIn($src, $content);
        $chapters[] = $src;
        $contents[] = $content;
        $found[] = $diagrams;
        $total = $total + len($diagrams);
    }
    def replies as list of string;
    if ($total == 0) {
        return kit.preprocessorReply($replies);
    }
    def r as Renderer init rendererFor($s);
    # One render per distinct diagram, remembered with the first fence that
    # asked for it, which is the one an error names.
    def items as list of json.Value;
    def seen as map of string to int;
    for (def diagrams in $found) {
        for (def d in $diagrams) {
            def name as string init nameOf($r, $d.source);
            if (maps.has($seen, $name)) {
                continue;
            }
            $seen[$name] = 1;
            $items[] = json.decode('{"name":' + json.encode($name) +
                ',"source":' + json.encode($d.source) +
                ',"chapter":' + json.encode($d.chapter) +
                ',"line":' + convert.toString($d.line) + '}');
        }
    }
    kit.work($s.jobs, drawItem, contextOf($r.settings, $dir), $items);
    for (def c in 0..len($chapters)) {
        if (len($found[$c]) == 0) {
            continue;
        }
        def targets as list of string;
        for (def d in $found[$c]) {
            $targets[] = kit.generatedLink($chapters[$c], $plugin, nameOf($r, $d.source) + ".svg");
        }
        $replies[] = kit.chapterReply($chapters[$c], rewrite($contents[$c], $found[$c], $targets));
    }
    return kit.preprocessorReply($replies);
}

/**
 * Run the plugin over one request.
 * @param request {string} the JSON request from stdin
 * @return {int} the exit status
 */
export func run(request as string) {
    try {
        io.printf("%s", replyFor(kit.request($request, "preprocessor")));
        return 0;
    } catch (e) {
        return kit.report("grimoire-mermaid", $e.message);
    }
}
