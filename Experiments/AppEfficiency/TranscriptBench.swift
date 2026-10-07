import Foundation
import Darwin
@main struct Bench {
 static func main() {
  var results: [Double] = []
  for _ in 0..<4 {
   var timeline = CatchUpTimeline()
   timeline.upsert((0..<5000).map { .init(id: String(format: "%05d", $0), speaker: nil, text: "Message", spokenAt: Date(timeIntervalSince1970: Double($0))) })
   let start = clock()
   for i in 0..<2000 {
    let index = i % 5000
    timeline.upsert([.init(id: String(format: "%05d", index), speaker: "Speaker", text: "Corrected \(i)", spokenAt: Date(timeIntervalSince1970: Double(index)))])
   }
   results.append(Double(clock() - start) / Double(CLOCKS_PER_SEC) * 1000)
   precondition(timeline.segments.count == 5000)
  }
  print(results.sorted(), "CPU ms / 2000 corrections at 5000 retained messages")
 }
}
