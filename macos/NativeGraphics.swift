import Foundation
import CryptoKit
import CoreFoundation

struct NativeGraphics {
    let root:URL
    private let manifest:[String:Any]
    var executable:URL {root.appendingPathComponent("bin/qemu-system-aarch64")}
    var supportsDynamicMemory:Bool {manifest["hvf_dynamic_memory_version"] as? Int == 1}
    var supportsMixedDisplays:Bool {manifest["mixed_display_identity_version"] as? Int == 1}

    init(root:URL)throws{
        self.root=root
        let bytes=try Data(contentsOf:root.appendingPathComponent("runtime.json"))
        guard bytes.count<=65536,let value=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              value["schema"] as? Int == 1,let wire=value["guest_wire_version"] as? Int,
              (wire == 1 || (wire == 2 &&
                value["renderer_source_pin"] as? String == "cf5af71359b224a9a482e9b5a67f8160497dc951" &&
                value["protocol_source_pin"] as? String == "f510a6e41ea89a6d626de4da9d9b02978a770e37" &&
                value["paired_guest_protocol_files"] as? Int == 311 &&
                value["query_feedback_end_generation"] as? Int == 1 && value["resource_update_context"] as? Int == 1)),
              value["host_transport_version"] as? Int == 3,value["native_descriptor_version"] as? Int == 2,
              value["input_backpressure"] as? Bool == true,
              [1,2,3].contains(value["renderer_control_version"] as? Int ?? 1),
              (((value["renderer_control_version"] as? Int ?? 1) >= 2) == (value["context_retirement"] as? Int == 1)),
              ((value["renderer_control_version"] as? Int == 3) == (value["resource_retirement"] as? Int == 1)),
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
    func environment(directory:URL,session:String,primary:HostDisplay?=nil)->[String:String]{
        let libraries=root.appendingPathComponent("lib").path
        var values=["DYLD_LIBRARY_PATH":libraries,"DYLD_FALLBACK_LIBRARY_PATH":libraries,
            "PERP_WGC_EXPORT_SOCKET":NativeWindowFrames.shared.socketPath,
            "NPT_BACKEND":"dxmt","ANGLE_DEFAULT_PLATFORM":"metal",
            "RENDER_SERVER_EXEC_PATH":root.appendingPathComponent("bin/virgl_render_server").path,
            "PERP_NEPTUNE_SCANOUT_BROKER":"1","PERP_NATIVE_DISPLAY_DIRECT":"1",
            "PERP_NEPTUNE_CONTEXT_RETIREMENT":manifest["context_retirement"] as? Int == 1 ? "1":"0",
            "PERP_NATIVE_DISPLAY_DIR":directory.path,"PERP_NATIVE_DISPLAY_SESSION":session,
            "PERP_HVF_STP_Q_PCI_HOLE":"1"]
        // These describe only the primary monitor at the next boot. A live
        // geometry change does not imply that the guest refreshed its EDID.
        if let version=manifest["primary_monitor_metadata"] as? NSNumber,
           CFGetTypeID(version) != CFBooleanGetTypeID(),version.doubleValue == 1,
           let primary,primary.primary,let width=primary.physicalWidthMM,
           let height=primary.physicalHeightMM,let identity=primary.stableID {
            values["PERP_PRIMARY_MONITOR_WIDTH_MM"]=String(width)
            values["PERP_PRIMARY_MONITOR_HEIGHT_MM"]=String(height)
            values["PERP_PRIMARY_MONITOR_ID"]=identity
        }
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
    let wgcSocket:String?
}
