import SwiftUI

// Explicit property-wrapper alias also works with SDKs that expose a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>
