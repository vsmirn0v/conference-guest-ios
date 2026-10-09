import Foundation
@main struct Normalize {
 static func main() throws {
  for arg in CommandLine.arguments.dropFirst() {
   let url=URL(fileURLWithPath:arg), original=try Data(contentsOf:url)
   let result=H264ColorSignalling.applying(.init(primaries:1,transfer:1,matrix:1), to:original)
   precondition(H264ColorSignalling.applying(.init(primaries:1,transfer:1,matrix:1), to:result)==result)
   try result.write(to:url.appendingPathExtension("normalized"))
   print(url.lastPathComponent, original.count, result.count)
  }
 }
}
