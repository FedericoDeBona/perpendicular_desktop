import Foundation
import CryptoKit

struct NativeGraphics {
    let root:URL
    private let manifest:[String:Any]
    var executable:URL {root.appendingPathComponent("bin/qemu-system-aarch64")}

    init(root:URL)throws{
        self.root=root
        let bytes=try Data(contentsOf:root.appendingPathComponent("runtime.json"))
        guard bytes.count<=65536,let value=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              value["schema"] as? Int == 1,value["guest_wire_version"] as? Int == 1,
              value["host_transport_version"] as? Int == 3,value["native_descriptor_version"] as? Int == 2,
              value["input_backpressure"] as? Bool == true,
              [1,2].contains(value["renderer_control_version"] as? Int ?? 1),
              ((value["renderer_control_version"] as? Int == 2) == (value["context_retirement"] as? Int == 1)),
              let files=value["files"] as? [String:String],files.count<=64,
              ["bin/qemu-system-aarch64","bin/virgl_render_server","lib/libdxmt-native.dylib","lib/libvirglrenderer.1.dylib"].allSatisfy({files[$0] != nil}) else{
            throw Self.failure("The Windows graphics runtime is incomplete or incompatible.")
        }
        for (path,expected) in files {
            guard !path.hasPrefix("/"),!path.split(separator:"/").contains("..") else{throw Self.failure("Invalid graphics runtime path.")}
            let data=try Data(contentsOf:root.appendingPathComponent(path),options:.mappedIfSafe)
            let actual=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
            guard actual == expected else{throw Self.failure("The Windows graphics runtime has changed: \(path)")}
        }
        manifest=value
    }
    func environment(directory:URL,session:String)->[String:String]{
        let libraries=root.appendingPathComponent("lib").path
        var values=["DYLD_LIBRARY_PATH":libraries,"DYLD_FALLBACK_LIBRARY_PATH":libraries,
            "NPT_BACKEND":"dxmt","ANGLE_DEFAULT_PLATFORM":"metal",
            "RENDER_SERVER_EXEC_PATH":root.appendingPathComponent("bin/virgl_render_server").path,
            "PERP_NEPTUNE_SCANOUT_BROKER":"1","PERP_NATIVE_DISPLAY_DIRECT":"1",
            "PERP_NEPTUNE_CONTEXT_RETIREMENT":manifest["context_retirement"] as? Int == 1 ? "1":"0",
            "PERP_NATIVE_DISPLAY_DIR":directory.path,"PERP_NATIVE_DISPLAY_SESSION":session,
            "PERP_HVF_STP_Q_PCI_HOLE":"1"]
        let flags=["hvf_strh_post2_hole_default_off":"PERP_HVF_STRH_POST_PCI_HOLE",
            "hvf_stp_s_hole_default_off":"PERP_HVF_STP_S_PCI_HOLE",
            "hvf_str_q_hole_default_off":"PERP_HVF_STR_Q_PCI_HOLE",
            "hvf_stp_q_cross_page_hole_default_off":"PERP_HVF_STP_Q_CROSS_PAGE_PCI_HOLE",
            "hvf_single_cross_page_hole_default_off":"PERP_HVF_SINGLE_CROSS_PAGE_PCI_HOLE",
            "hvf_str_simd_hole_default_off":"PERP_HVF_STR_SIMD_PCI_HOLE",
            "hvf_str_simd_writeback_hole_default_off":"PERP_HVF_STR_SIMD_WRITEBACK_PCI_HOLE",
            "hvf_str_integer_writeback_hole_default_off":"PERP_HVF_STR_INTEGER_WRITEBACK_PCI_HOLE"]
        for (capability,variable) in flags {values[variable]=manifest[capability] as? Bool == true ? "1":"0"}
        for name in ["NPT_D3D11_LIBRARY_PATH","NPT_DXGI_LIBRARY_PATH","NPT_D3D12_LIBRARY_PATH"] {
            values[name]=root.appendingPathComponent("lib/libdxmt-native.dylib").path
        }
        return values
    }
    private static func failure(_ message:String)->NSError{NSError(domain:"Graphics",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
}

struct DesktopLaunch:Codable {
    let machineID:String
    let pid:Int32
    let socket:String
    let native:NativeDisplayEndpoint?
}
