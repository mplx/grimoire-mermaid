# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

/**
 * White-box tests for `mermaid.j`, run by `jennifer test src/mermaid_test.j`
 * from the repository root (`scripts/test.sh` does that).
 *
 * The renderer is `tests/fake-renderer`, a shell script given through
 * `program`, which takes both command lines, writes a small text file and can
 * be told to fail, stall or write nothing. The real renderers are tried at the
 * end, each only when it is installed: two builds have to give the same bytes.
 * @module mermaid_test
 * @author mplx <mplx@jennifer-lang.dev>
 * @license LGPL-3.0-only
 */
use testing;
use os;

# The fake renderer, by absolute path: the plugin runs it as a program.
func fake() {
    return path.join(os.cwd(), "tests/fake-renderer");
}

def const FLOW as string init "```mermaid\nflowchart LR\n  A --> B\n```\n";

# A request as Grimoire 0.5.0 sends it, with `files` pointing at a fresh
# directory. `settings` is JSON. Raw strings for the JSON around it: a cooked
# one would read the braces as interpolations.
func requestWith(files as string, settings as string, chapters as map of string to string) {
    def parts as list of string;
    for (def src in $chapters) {
        $parts[] = '{"src":' + json.encode($src) + ',"content":' +
            json.encode($chapters[$src]) + '}';
    }
    return '{"api":1,"kind":"preprocessor","features":["files"],' +
        '"book":{"title":"T","description":"","authors":[],"language":"en",' +
        '"src":"docs","out":"site","generated":' + json.encode(path.dir($files)) + '},' +
        '"plugin":{"name":"mermaid","settings":' + $settings + ',"files":' + json.encode($files) +
        '},"entries":[],"chapters":[' + strings.join($parts, ",") + ']}';
}

# The settings that run the fake as merman. The font can be any file: only its
# digest is used, and the fake ignores it.
func fakeSettings(extra as string) {
    return '{"program":' + json.encode(fake()) + ',"font":' + json.encode(fake()) + $extra + '}';
}

# Answer a request built by `requestWith`.
func replyTo(files as string, settings as string, chapters as map of string to string) {
    return replyFor(json.decode(requestWith($files, $settings, $chapters)));
}

func filesDir() {
    def root as string init fs.makeTempDir(os.tempDir(), "mermaid-test-");
    def dir as string init path.join($root, "_generated/mermaid");
    fs.mkdirAll($dir);
    return $dir;
}

func one(src as string, content as string) {
    def out as map of string to string;
    $out[$src] = $content;
    return $out;
}

# The rewritten chapter `src` in a reply, or "" when the reply leaves it alone.
func chapterIn(reply as string, src as string) {
    def doc as json.Value init json.decode($reply);
    for (def i in 0..json.length($doc, "/chapters")) {
        def at as string init "/chapters/" + convert.toString($i);
        if (json.asString($doc, $at + "/src") == $src) {
            return json.asString($doc, $at + "/content");
        }
    }
    return "";
}

func cleanUp(files as string) {
    fs.removeAll(path.dir(path.dir($files)));
}

# The names in a directory, sorted.
func listed(dir as string) {
    def out as list of string;
    for (def name in fs.list($dir)) {
        $out[] = $name;
    }
    return lists.sort($out);
}

# --- fences -----------------------------------------------------------
#
# The fence rules are the kit's (`pluginkit_test.j` in Grimoire); these cover
# what this plugin does with them.

func testABacktickFenceIsFound() {
    def found as list of Diagram init diagramsIn("a.md", "# A\n\n" + FLOW + "\nafter\n");
    testing.assertEqual(len($found), 1);
    testing.assertEqual($found[0].line, 3);
    testing.assertEqual($found[0].first, 2);
    testing.assertEqual($found[0].last, 5);
    testing.assertEqual($found[0].source, "flowchart LR\n  A --> B\n");
    testing.assertEqual($found[0].alt, "Diagram");
}

# The language is the info string's first word, compared exactly.
func testOnlyTheMermaidLanguageCounts() {
    testing.assertEqual(len(diagramsIn("a.md", "```mermaid title\ng\n```\n")), 1);
    testing.assertEqual(len(diagramsIn("a.md", "```mermaidjs\ng\n```\n")), 0);
    testing.assertEqual(len(diagramsIn("a.md", "```Mermaid\ng\n```\n")), 0);
    testing.assertEqual(len(diagramsIn("a.md", "```js\ng\n```\n")), 0);
}

# A mermaid fence shown as an example, inside a longer fence or as indented
# code, is not a diagram. The fence rules themselves are the kit's, and its
# tests cover them.
func testAFenceShownAsAnExampleIsLeftAlone() {
    def nested as string init "````markdown\n" + FLOW + "````\n";
    testing.assertEqual(len(diagramsIn("a.md", $nested)), 0);
    testing.assertEqual(len(diagramsIn("a.md", "text\n\n    ```mermaid\n    g\n    ```\n")), 0);
    testing.assertEqual(len(diagramsIn("a.md", $nested + "\n" + FLOW)), 1);
}

func unclosed() {
    diagramsIn("guide/a.md", "text\n\n```mermaid\ngraph\n");
}

# An unclosed mermaid fence is a mistake, and a picture of half a chapter is not
# what anyone meant.
func testAnUnclosedMermaidFenceIsRefused() {
    testing.assertThrows("unclosed", "plugin");
    try {
        unclosed();
    } catch (e) {
        testing.assertContains($e.message, "guide/a.md:3:");
    }
}

func oversized() {
    diagramsIn("a.md", "```mermaid\n" + strings.repeat("x", MAX_SOURCE) + "\n```\n");
}

func testADiagramOverTheCapThrowsLimit() {
    testing.assertThrows("oversized", "limit");
}

# --- alt text and the rewrite -----------------------------------------

func testTheAltTextIsTheAccessibilityTitle() {
    testing.assertEqual(altOf("flowchart LR\n  accTitle: Build flow \n  A --> B\n"), "Build flow");
    testing.assertEqual(altOf("graph\n  accTitle:\n"), "Diagram");
    testing.assertEqual(altOf("graph\n  accDescr: not this\n"), "Diagram");
}

# What would be markup inside `![...]` is escaped; brackets become parentheses,
# because the printable book reads an image up to its first `]`.
func testTheAltTextIsMadeSafe() {
    testing.assertEqual(altMarkdown("a *b* [c] <d> e_f"), 'a \*b\* (c) \<d\> e\_f');
    testing.assertEqual(altMarkdown("plain words"), "plain words");
}

func testAFenceBecomesAParagraphOfItsOwn() {
    def content as string init "before\n```mermaid\ngraph\n```\nafter\n";
    def out as string init rewrite($content, diagramsIn("a.md", $content), ["x.svg"]);
    testing.assertEqual($out, "before\n\n![Diagram](x.svg)\n\nafter\n");
    def spaced as string init "before\n\n```mermaid\ngraph\n```\n\nafter\n";
    testing.assertEqual(
        rewrite($spaced, diagramsIn("a.md", $spaced), ["x.svg"]),
        "before\n\n![Diagram](x.svg)\n\nafter\n");
}

# Inside a list item the fence's indentation keeps the picture in the item.
func testTheFencesIndentationIsKept() {
    def content as string init "- item\n\n  ```mermaid\n  graph\n  ```\n";
    testing.assertEqual(
        rewrite($content, diagramsIn("a.md", $content), ["x.svg"]),
        "- item\n\n  ![Diagram](x.svg)\n");
}

# --- settings ---------------------------------------------------------

func settingsIn(settings as string) {
    return settingsOf(json.decode('{"plugin":{"name":"mermaid","settings":' + $settings + '}}'));
}

func testTheDefaults() {
    def s as Settings init settingsIn('{}');
    testing.assertEqual($s.renderer, "merman");
    testing.assertEqual($s.program, "merman-cli");
    testing.assertEqual($s.theme, "neutral");
    testing.assertEqual($s.font, "");
    testing.assertTrue($s.png);
    testing.assertEqual($s.scale, 2.0);
    testing.assertEqual($s.jobs, 0);
    testing.assertEqual(settingsIn('{"renderer":"mmdr"}').program, "mmdr");
}

# Grimoire passes its own `command` and `args` in the same table.
func testGrimoiresOwnKeysAreAccepted() {
    def s as Settings init settingsIn('{"command":"./bin/grimoire-mermaid","args":["-x"]}');
    testing.assertEqual($s.program, "merman-cli");
}

func testTheSettingsAreRead() {
    def s as Settings init settingsIn(
        '{"renderer":"mmdr","program":"/opt/mmdr","theme":"dark","png":false,' +
            '"scale":1.5,"jobs":3}');
    testing.assertEqual($s.program, "/opt/mmdr");
    testing.assertEqual($s.theme, "dark");
    testing.assertFalse($s.png);
    testing.assertEqual($s.scale, 1.5);
    testing.assertEqual($s.jobs, 3);
}

func unknownKey() {
    settingsIn('{"them":"dark"}');
}

func pngNotBool() {
    settingsIn('{"png":"yes"}');
}

func badRenderer() {
    settingsIn('{"renderer":"mmdc"}');
}

func fontForMmdr() {
    settingsIn('{"renderer":"mmdr","font":"x.ttf"}');
}

func scaleTooBig() {
    settingsIn('{"scale":9}');
}

func scaleZero() {
    settingsIn('{"scale":0}');
}

func negativeJobs() {
    settingsIn('{"jobs":-1}');
}

func emptyTheme() {
    settingsIn('{"theme":""}');
}

# Strict: every one of these is a book that would be drawn some way nobody
# asked for.
func testBadSettingsAreRefused() {
    testing.assertThrows("unknownKey", "plugin");
    testing.assertThrows("pngNotBool", "plugin");
    testing.assertThrows("badRenderer", "plugin");
    testing.assertThrows("fontForMmdr", "plugin");
    testing.assertThrows("scaleTooBig", "plugin");
    testing.assertThrows("scaleZero", "plugin");
    testing.assertThrows("negativeJobs", "plugin");
    testing.assertThrows("emptyTheme", "plugin");
    try {
        unknownKey();
    } catch (e) {
        testing.assertContains($e.message, "`them`");
        testing.assertContains($e.message, "renderer, program, theme");
    }
}

func testTheScaleIsSpelledAsWritten() {
    testing.assertEqual(scaleText(2.0), "2");
    testing.assertEqual(scaleText(1.5), "1.5");
}

# --- names ------------------------------------------------------------

func rendererOf(theme as string, png as bool) {
    def s as Settings init settingsIn('{}');
    $s.theme = $theme;
    $s.png = $png;
    return Renderer{settings: $s, version: "merman-cli 0.10.0", fontDigest: "f"};
}

# What changes the picture changes the name; where the program is and how many
# jobs draw do not.
func testTheNameCoversWhatChangesThePicture() {
    def base as Renderer init rendererOf("neutral", true);
    def name as string init nameOf($base, "graph\n");
    testing.assertEqual(len($name), NAME_DIGITS);
    testing.assertEqual(nameOf($base, "graph\n"), $name);
    testing.assertNotEqual(nameOf($base, "graph \n"), $name);
    testing.assertNotEqual(nameOf(rendererOf("dark", true), "graph\n"), $name);
    testing.assertNotEqual(nameOf(rendererOf("neutral", false), "graph\n"), $name);
    def newer as Renderer init $base;
    $newer.version = "merman-cli 0.11.0";
    testing.assertNotEqual(nameOf($newer, "graph\n"), $name);
    def font as Renderer init $base;
    $font.fontDigest = "g";
    testing.assertNotEqual(nameOf($font, "graph\n"), $name);
    def moved as Renderer init $base;
    $moved.settings.program = "/elsewhere/merman-cli";
    $moved.settings.jobs = 7;
    testing.assertEqual(nameOf($moved, "graph\n"), $name);
}

# --- the request ------------------------------------------------------

# A Grimoire without the feature has nowhere to put a picture, so the request is
# refused with the version that has.
func testARequestWithoutTheFilesFeatureIsRefused() {
    def old as string init '{"api":1,"kind":"preprocessor","book":{},' +
        '"plugin":{"name":"mermaid","settings":{}},"entries":[],"chapters":[]}';
    def threw as bool init false;
    try {
        replyFor(json.decode($old));
    } catch (e) {
        $threw = true;
        testing.assertEqual($e.kind, "plugin");
        testing.assertContains($e.message, "Grimoire 0.5.0");
        testing.assertContains($e.message, "`files`");
    }
    testing.assertTrue($threw);
}

func testRunRefusesWhatItCannotAnswer() {
    def files as string init filesDir();
    def good as string init requestWith($files, fakeSettings(""), one("a.md", "x\n"));
    testing.assertEqual(run($good), 0);
    testing.assertEqual(run(""), 1);
    testing.assertEqual(run(strings.replace($good, '"api":1', '"api":2')), 1);
    testing.assertEqual(run(strings.replace($good, '"preprocessor"', '"renderer"')), 1);
    cleanUp($files);
}

# A book with no diagram needs no renderer: nothing is run, nothing rewritten.
func testABookWithoutDiagramsRunsNothing() {
    def files as string init filesDir();
    def reply as string init replyTo(
        $files,
        '{"program":"/no/such/renderer"}',
        one("a.md", "```sh\nls\n```\n"));
    testing.assertEqual(json.length(json.decode($reply), "/chapters"), 0);
    testing.assertEqual(len(fs.list($files)), 0);
    cleanUp($files);
}

func testADiagramIsDrawnAndLinked() {
    def files as string init filesDir();
    def chapters as map of string to string;
    $chapters["index.md"] = "# One\n\n" + FLOW;
    $chapters["guide/two.md"] = "# Two\n\n```mermaid\nsequenceDiagram\n" +
        "  accTitle: Hello\n  A->>B: hi\n```\n";
    $chapters["plain.md"] = "# Plain\n";
    def reply as string init replyTo($files, fakeSettings(""), $chapters);
    def index as string init chapterIn($reply, "index.md");
    def two as string init chapterIn($reply, "guide/two.md");
    testing.assertEqual(chapterIn($reply, "plain.md"), "");
    def m as regex.Match init regex.find(
        '!\[Diagram\]\(_generated/mermaid/([0-9a-f]{16})\.svg\)',
        $index);
    testing.assertTrue($m.start >= 0);
    testing.assertTrue(regex.matches(
        '!\[Hello\]\(\.\./_generated/mermaid/[0-9a-f]{16}\.svg\)',
        $two));
    def name as string init $m.groups[0];
    def svg as string init fs.readString(path.join($files, $name + ".svg"));
    testing.assertContains($svg, "--svg-pipeline resvg-safe");
    testing.assertContains($svg, "-t neutral");
    testing.assertContains($svg, "flowchart LR");
    def png as string init fs.readString(path.join($files, $name + ".png"));
    testing.assertContains($png, "png: render - -o");
    testing.assertContains($png, "-s 2");
    testing.assertContains($png, "--font-file");
    testing.assertEqual(len(fs.list($files)), 4);
    cleanUp($files);
}

func testPngFalseWritesTheSvgOnly() {
    def files as string init filesDir();
    replyTo($files, fakeSettings(',"png":false'), one("a.md", FLOW));
    def names as list of string init listed($files);
    testing.assertEqual(len($names), 1);
    testing.assertTrue(strings.endsWith($names[0], ".svg"));
    cleanUp($files);
}

# The same diagram twice is drawn once, under one name.
func testTheSameDiagramIsDrawnOnce() {
    def files as string init filesDir();
    def chapters as map of string to string;
    $chapters["a.md"] = FLOW + "\n" + FLOW;
    $chapters["b.md"] = FLOW;
    def reply as string init replyTo($files, fakeSettings(',"png":false'), $chapters);
    testing.assertEqual(len(fs.list($files)), 1);
    testing.assertEqual(strings.count(chapterIn($reply, "a.md"), "_generated/mermaid/"), 2);
    cleanUp($files);
}

# mmdr has no scale: the PNG is asked for at the diagram's own size, which
# `--size` reports, times the scale.
func testMmdrIsAskedForItsSizeTimesTheScale() {
    def files as string init filesDir();
    replyTo($files, '{"renderer":"mmdr","program":' + json.encode(fake()) + '}', one("a.md", FLOW));
    for (def name in listed($files)) {
        def text as string init fs.readString(path.join($files, $name));
        if (strings.endsWith($name, ".png")) {
            testing.assertContains($text, "png: -i - -o");
            testing.assertContains($text, "-w 201 -H 80");
        } else {
            testing.assertContains($text, "svg: -i - -o");
            testing.assertContains($text, "-t neutral");
        }
    }
    cleanUp($files);
}

# The error names the chapter, the fence's line and the renderer's first line.
func testARefusedDiagramStopsTheBuild() {
    def files as string init filesDir();
    def chapters as map of string to string;
    $chapters["a.md"] = FLOW;
    $chapters["guide/b.md"] = "# B\n\ntext\n\n```mermaid\nBROKEN\n```\n";
    def threw as bool init false;
    try {
        replyTo($files, fakeSettings(""), $chapters);
    } catch (e) {
        $threw = true;
        testing.assertEqual($e.kind, "plugin");
        testing.assertEqual(
            $e.message,
            "guide/b.md:5: " + fake() + ": Diagram parse error: broken on purpose");
        testing.assertEqual($e.file, "guide/b.md");
        testing.assertEqual($e.line, 5);
    }
    testing.assertTrue($threw);
    cleanUp($files);
}

# Two failures report the first in the book, whichever finished first.
func testTheFirstFailureInTheBookIsReported() {
    def files as string init filesDir();
    def chapters as map of string to string;
    $chapters["a.md"] = "```mermaid\nSLOW BROKEN one\n```\n";
    $chapters["b.md"] = "```mermaid\nBROKEN two\n```\n";
    def threw as bool init false;
    try {
        replyTo($files, fakeSettings(',"jobs":2'), $chapters);
    } catch (e) {
        $threw = true;
        testing.assertContains($e.message, "a.md:1:");
    }
    testing.assertTrue($threw);
    cleanUp($files);
}

func testARendererThatWritesNothingIsAnError() {
    def files as string init filesDir();
    def threw as bool init false;
    try {
        replyTo($files, fakeSettings(""), one("a.md", "```mermaid\nSILENT\n```\n"));
    } catch (e) {
        $threw = true;
        testing.assertContains($e.message, "wrote no ");
    }
    testing.assertTrue($threw);
    cleanUp($files);
}

func testAMissingRendererSaysWhatToInstall() {
    def files as string init filesDir();
    def threw as bool init false;
    try {
        replyTo($files, '{"program":"grimoire-mermaid-no-such-renderer"}', one("a.md", FLOW));
    } catch (e) {
        $threw = true;
        testing.assertEqual($e.kind, "plugin");
        testing.assertContains($e.message, "install merman-cli");
        testing.assertContains($e.message, "`program`");
    }
    testing.assertTrue($threw);
    cleanUp($files);
}

func testAMissingFontIsRefused() {
    def files as string init filesDir();
    def threw as bool init false;
    try {
        replyTo(
            $files,
            '{"program":' + json.encode(fake()) + ',"font":"/no/such/font.ttf"}',
            one("a.md", FLOW));
    } catch (e) {
        $threw = true;
        testing.assertContains($e.message, "font file not found");
    }
    testing.assertTrue($threw);
    cleanUp($files);
}

# --- concurrency ------------------------------------------------------

# The highest number of renders the fake saw running at once.
func peakOf(dir as string) {
    def most as int init 0;
    for (def line in strings.split(strings.trim(fs.readString(path.join($dir, "peak"))), "\n")) {
        def n as int init convert.toInt(strings.trim($line));
        if ($n > $most) {
            $most = $n;
        }
    }
    return $most;
}

func fourDiagrams() {
    def chapters as map of string to string;
    for (def i in 0..4) {
        def n as string init convert.toString($i);
        $chapters["c" + $n + ".md"] = "```mermaid\ngraph " + $n + "\n```\n";
    }
    return $chapters;
}

func testJobsBoundsHowManyRenderAtOnce() {
    def marks as string init fs.makeTempDir(os.tempDir(), "mermaid-marks-");
    os.setEnv("FAKE_RENDERER_DIR", $marks);
    def files as string init filesDir();
    replyTo($files, fakeSettings(',"png":false,"jobs":1'), fourDiagrams());
    testing.assertEqual(peakOf($marks), 1);
    fs.remove(path.join($marks, "peak"));
    def again as string init filesDir();
    replyTo($again, fakeSettings(',"png":false,"jobs":4'), fourDiagrams());
    testing.assertTrue(peakOf($marks) > 1);
    os.unsetEnv("FAKE_RENDERER_DIR");
    fs.removeAll($marks);
    cleanUp($files);
    cleanUp($again);
}

# The reply and the files are the same at any `jobs`, with the first diagram
# the slowest, so the order renders finish in is not the order of the book.
func testTheResultDoesNotDependOnTheOrderRendersFinish() {
    def chapters as map of string to string init fourDiagrams();
    $chapters["c0.md"] = "```mermaid\ngraph SLOW\n```\n";
    def serial as string init filesDir();
    def parallel as string init filesDir();
    def a as string init replyTo($serial, fakeSettings(',"jobs":1'), $chapters);
    def b as string init replyTo($parallel, fakeSettings(',"jobs":4'), $chapters);
    testing.assertEqual($a, $b);
    testing.assertEqual(listed($serial), listed($parallel));
    for (def name in listed($serial)) {
        # The files record the `-o` path, which differs; the rest must not.
        def x as string init fs.readString(path.join($serial, $name));
        def y as string init fs.readString(path.join($parallel, $name));
        testing.assertEqual(strings.replace($x, $serial, "D"), strings.replace($y, $parallel, "D"));
    }
    cleanUp($serial);
    cleanUp($parallel);
}

# --- the real renderers -----------------------------------------------

func installed(program as string) {
    def r as os.Result init os.run(["sh", "-c", "command -v " + $program]);
    return $r.exitCode == 0;
}

def const REAL_BOOK as string init "# Diagrams\n\n```mermaid\nflowchart LR\n  accTitle: Flow\n" +
    "  A[Start] --> B\{Ok?\}\n  B -->|yes| C[Done]\n```\n\n" +
    "```mermaid\nsequenceDiagram\n  Alice->>Bob: Hello\n  Bob-->>Alice: Hi\n```\n\n" +
    "```mermaid\ngantt\n  dateFormat YYYY-MM-DD\n  section Build\n  Write :a1, 2026-01-01, 3d\n" +
    "  Check :after a1, 2d\n```\n";

# Two builds, two directories, the same bytes in each.
func sameBytesTwice(settings as string) {
    def first as string init filesDir();
    def second as string init filesDir();
    def a as string init replyTo($first, $settings, one("a.md", REAL_BOOK));
    def b as string init replyTo($second, $settings, one("a.md", REAL_BOOK));
    testing.assertEqual($a, $b);
    def names as list of string init listed($first);
    testing.assertEqual(len($names), 6);
    testing.assertEqual($names, listed($second));
    for (def name in $names) {
        testing.assertEqual(
            fs.readBytes(path.join($first, $name)),
            fs.readBytes(path.join($second, $name)));
        if (strings.endsWith($name, ".svg")) {
            testing.assertFalse(strings.contains(
                fs.readString(path.join($first, $name)),
                "foreignObject"));
        }
    }
    cleanUp($first);
    cleanUp($second);
}

func testMermanDrawsTheSameBytesTwice() {
    if (not installed("merman-cli")) {
        return;
    }
    sameBytesTwice('{}');
}

func testMmdrDrawsTheSameBytesTwice() {
    if (not installed("mmdr")) {
        return;
    }
    sameBytesTwice('{"renderer":"mmdr"}');
}
