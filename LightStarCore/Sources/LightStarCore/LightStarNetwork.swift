import Foundation
import Network

func makeLightStarTCPParameters() -> NWParameters {
    let params = NWParameters.tcp
    params.includePeerToPeer = true
    params.allowLocalEndpointReuse = true
    params.serviceClass = .signaling
    if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
    }
    return params
}

func makeLightStarBrowseParameters() -> NWParameters {
    let params = NWParameters()
    params.includePeerToPeer = true
    return params
}

func lightStarNetworkErrorMessage(_ error: NWError) -> String {
    // kDNSServiceErr_NoAuth
    if case .dns(let code) = error, Int32(code) == -65555 {
        return "Local Network access denied. On iPhone go to Settings → LightStar → Local Network and turn it on, then try again."
    }
    return error.localizedDescription
}
