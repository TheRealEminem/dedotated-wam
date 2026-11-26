import SwiftUI

/// View-local state. Stands in for `@State`, which in the current SDK is a macro whose compiler
/// plugin ships only with full Xcode; this keeps the project buildable with the Command Line Tools.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>

    init(wrappedValue: Value) {
        storage = SwiftUI.State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
