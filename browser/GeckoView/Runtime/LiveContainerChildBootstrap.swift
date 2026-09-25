//
//  LiveContainerChildBootstrap.swift
//  Reynard
//

import Foundation

// Inside LiveContainer, Gecko child processes run in LiveContainer's
// LiveProcess extension instead of Reynard Helper. LiveProcess loads
// ReynardLiveContainerLoader.dylib, which loads GeckoView and calls
// ReynardChildBootstrap on the main thread. It does the same work as
// ProcessBootstrap in Helper/Helper.swift. Nothing calls it outside
// LiveContainer.

@objc private protocol LiveContainerBootstrapPing {
    func ping()
}

private final class LiveContainerProcessExtension: NSObject, GeckoProcessExtension {
    func lockdownSandbox(_ revision: String) {}
}

private enum LiveContainerChildBootstrap {
    // ChildProcessInit does not retain the process object, and the connection
    // has to stay open for the life of the child process.
    static var connection: NSXPCConnection?
    static var process: LiveContainerProcessExtension?
}

@_cdecl("ReynardChildBootstrap")
public func reynardChildBootstrap(_ endpoint: NSXPCListenerEndpoint) -> Bool {
    guard LiveContainerChildBootstrap.connection == nil else {
        return false
    }

    let connection = NSXPCConnection(listenerEndpoint: endpoint)
    connection.remoteObjectInterface = NSXPCInterface(with: LiveContainerBootstrapPing.self)
    connection.resume()

    guard let xpcConnection = XPCConnectionFromNSXPC(connection) else {
        connection.invalidate()
        return false
    }

    let process = LiveContainerProcessExtension()
    LiveContainerChildBootstrap.connection = connection
    LiveContainerChildBootstrap.process = process
    GeckoRuntime.childMain(xpcConnection: xpcConnection, process: process)
    (connection.remoteObjectProxyWithErrorHandler({ _ in }) as? LiveContainerBootstrapPing)?.ping()
    return true
}
