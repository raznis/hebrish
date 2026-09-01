import Foundation
import LayoutFixCore

let usage = """
usage: BakeLexicon --en <en_50k.txt> --he <he_50k.txt> --out <lexicon.bin>
                   [--sys-words /usr/share/dict/words]

Turns "word count" frequency lists into a LayoutFix lexicon.
"""

let args = CLIArgs()
let enPath = args.require("en", usage: usage)
let hePath = args.require("he", usage: usage)
let outPath = args.require("out", usage: usage)

func note(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

note("reading frequency lists")
let (enCounts, enRejected) = try LexiconBuilder.readFrequencyList(path: enPath, script: .latin)
note("  \(enPath): \(enCounts.count) kept, \(enRejected) rejected")
let (heCounts, heRejected) = try LexiconBuilder.readFrequencyList(path: hePath, script: .hebrew)
note("  \(hePath): \(heCounts.count) kept, \(heRejected) rejected")

var floorWords: [String] = []
if let sysWords = args.string("sys-words") {
    floorWords = try LexiconBuilder.readWordList(path: sysWords)
    note("  \(sysWords): \(floorWords.count) candidate floor words")
}

note("training character models")
let (lexicon, stats) = LexiconBuilder.build(
    LexiconBuilder.Inputs(latinCounts: enCounts, hebrewCounts: heCounts,
                          latinFloorWords: floorWords))

let data = LexiconFormat.encode(lexicon)
let outURL = URL(fileURLWithPath: outPath)
try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try data.write(to: outURL)

// A lexicon that cannot be read back is a build failure, not a runtime surprise.
let reloaded = try LexiconFormat.decode(data)
precondition(reloaded.latin.unigrams.count == lexicon.latin.unigrams.count,
             "latin vocabulary lost in round-trip")
precondition(reloaded.hebrew.unigrams.count == lexicon.hebrew.unigrams.count,
             "hebrew vocabulary lost in round-trip")
precondition(reloaded.hebrew.ngram.trigrams.count == lexicon.hebrew.ngram.trigrams.count,
             "hebrew trigrams lost in round-trip")

func fmt(_ n: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

print("""
wrote \(outPath)  (\(fmt(data.count)) bytes)
  latin   \(fmt(lexicon.latin.unigrams.count)) words \
(\(fmt(stats.latinCorpusWords)) corpus + \(fmt(stats.latinFloorWords)) floor @ \
logP \(String(format: "%.1f", stats.floorLogProb)))
          \(fmt(lexicon.latin.ngram.trigrams.count)) trigrams, corpus total \(fmt(Int(stats.latinTotal)))
  hebrew  \(fmt(lexicon.hebrew.unigrams.count)) words
          \(fmt(lexicon.hebrew.ngram.trigrams.count)) trigrams, corpus total \(fmt(Int(stats.hebrewTotal)))
""")
