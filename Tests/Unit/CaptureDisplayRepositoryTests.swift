import CoreGraphics
import Testing

@testable import HaeCore

@Test
func displayDiscoveryUsesMetadataAndSortsMainFirst() throws {
  let displays = try CaptureDisplayRepository.availableDisplays(
    mainID: 20,
    displayList: displayListReader([30, 10, 20]),
    displaySize: { id in (Int(id) * 100, Int(id) * 50) }
  )

  #expect(
    displays == [
      CaptureDisplayDevice(id: 20, name: "Main display", width: 2_000, height: 1_000),
      CaptureDisplayDevice(id: 10, name: "Display 10", width: 1_000, height: 500),
      CaptureDisplayDevice(id: 30, name: "Display 30", width: 3_000, height: 1_500),
    ])
}

@Test
func displayDiscoverySortsByIDWhenMainDisplayIsAbsent() throws {
  let displays = try CaptureDisplayRepository.availableDisplays(
    mainID: 99,
    displayList: displayListReader([30, 10, 20]),
    displaySize: { _ in (1_920, 1_080) }
  )

  #expect(displays.map(\.id) == [10, 20, 30])
  #expect(displays.allSatisfy { $0.name != "Main display" })
}

@Test
func displayDiscoveryReturnsUniqueDisplayIDs() throws {
  let displays = try CaptureDisplayRepository.availableDisplays(
    mainID: 20,
    displayList: displayListReader([20, 10, 20, 30, 10]),
    displaySize: { _ in (1_920, 1_080) }
  )

  #expect(displays.map(\.id) == [20, 10, 30])
}

@Test
func displayDiscoveryHandlesNoActiveDisplays() throws {
  var listCalls = 0
  var sizeCalls = 0
  let displays = try CaptureDisplayRepository.availableDisplays(
    mainID: 0,
    displayList: { capacity, ids, count in
      listCalls += 1
      #expect(capacity == 0)
      #expect(ids == nil)
      count?.pointee = 0
      return .success
    },
    displaySize: { _ in
      sizeCalls += 1
      return (0, 0)
    }
  )

  #expect(displays.isEmpty)
  #expect(listCalls == 1)
  #expect(sizeCalls == 0)
}

@Test
func displayDiscoveryPropagatesCountFailure() {
  #expect(throws: CaptureDisplayRepositoryError.displayListFailed(.failure)) {
    try CaptureDisplayRepository.availableDisplays(
      mainID: 1,
      displayList: { _, _, _ in .failure },
      displaySize: { _ in
        Issue.record("Display sizes must not be read after enumeration fails.")
        return (0, 0)
      }
    )
  }
}

@Test
func displayDiscoveryPropagatesListFailure() {
  #expect(throws: CaptureDisplayRepositoryError.displayListFailed(.failure)) {
    try CaptureDisplayRepository.availableDisplays(
      mainID: 1,
      displayList: { _, ids, count in
        guard ids != nil else {
          count?.pointee = 1
          return .success
        }
        return .failure
      },
      displaySize: { _ in
        Issue.record("Display sizes must not be read after enumeration fails.")
        return (0, 0)
      }
    )
  }
}

@Test
func displayDiscoveryUsesReturnedCountWhenDisplayDisconnects() throws {
  let displays = try CaptureDisplayRepository.availableDisplays(
    mainID: 10,
    displayList: { capacity, ids, count in
      guard let ids else {
        count?.pointee = 3
        return .success
      }
      #expect(capacity == 3)
      ids[0] = 10
      count?.pointee = 1
      return .success
    },
    displaySize: { _ in (1_920, 1_080) }
  )

  #expect(displays.map(\.id) == [10])
}

private func displayListReader(
  _ displayIDs: [CGDirectDisplayID]
) -> (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError {
  { capacity, ids, count in
    guard let ids else {
      count?.pointee = UInt32(displayIDs.count)
      return .success
    }
    let returnedIDs = displayIDs.prefix(Int(capacity))
    for (index, id) in returnedIDs.enumerated() {
      ids[index] = id
    }
    count?.pointee = UInt32(returnedIDs.count)
    return .success
  }
}
