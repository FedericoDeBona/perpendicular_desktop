//! Windows Shell icons, resolved from the same AppsFolder identities as launch.
//! Call on a background thread: Shell extraction can access disk and is not a
//! UI/input operation. No COM interface is shared with the catalogue apartment.
use super::error;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use windows::{
    Win32::{
        Foundation::SIZE,
        Graphics::{
            Gdi::{DeleteObject, HBITMAP, HGDIOBJ, HPALETTE},
            Imaging::{
                CLSID_WICImagingFactory, GUID_ContainerFormatPng, GUID_VendorMicrosoft,
                GUID_WICPixelFormat32bppBGRA, IWICBitmapFrameEncode, IWICImagingFactory,
                WICBitmapDitherTypeNone, WICBitmapEncoderNoCache, WICBitmapPaletteTypeCustom,
                WICBitmapUsePremultipliedAlpha,
            },
        },
        System::Com::{
            CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx,
            CoUninitialize, STATFLAG_NONAME, STATSTG, STREAM_SEEK_SET,
        },
        UI::Shell::{
            FOLDERID_AppsFolder, IShellItem, IShellItemImageFactory, KF_FLAG_DEFAULT,
            SHCreateItemFromParsingName, SHCreateItemInKnownFolder, SHCreateMemStream,
            SIIGBF_ICONONLY,
        },
    },
    core::{Interface, PCWSTR},
};

const ICON_EDGE: u32 = 256;
const PNG_LIMIT: u64 = 512 * 1024;

fn at(stage: &'static str) -> impl FnOnce(windows::core::Error) -> String {
    move |value| format!("App icon {stage}: {}", error(value))
}

fn shell_item(parsing: &str) -> Result<IShellItem, String> {
    let name: Vec<u16> = parsing.encode_utf16().chain([0]).collect();
    unsafe {
        if std::path::Path::new(parsing).is_absolute()
            || parsing.starts_with("::")
            || parsing
                .get(..6)
                .is_some_and(|prefix| prefix.eq_ignore_ascii_case("shell:"))
        {
            SHCreateItemFromParsingName(PCWSTR(name.as_ptr()), None)
                .map_err(at("CreateItem(absolute)"))
        } else {
            // AppsFolder returns bare AUMIDs (also for desktop aliases such
            // as Microsoft.Windows.Explorer), not standalone filesystem names.
            // Resolve them inside their original namespace. The catalogue ID
            // remains the hash of the original, unprefixed parsing string.
            SHCreateItemInKnownFolder(&FOLDERID_AppsFolder, KF_FLAG_DEFAULT, PCWSTR(name.as_ptr()))
                .map_err(at("CreateItem(AppsFolder)"))
        }
    }
}

struct Apartment;
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe {
            CoUninitialize();
        }
    }
}
struct Bitmap(HBITMAP);
impl Drop for Bitmap {
    fn drop(&mut self) {
        unsafe {
            let _ = DeleteObject(HGDIOBJ(self.0.0));
        }
    }
}

fn base64(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut result = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let first = chunk[0];
        let second = *chunk.get(1).unwrap_or(&0);
        let third = *chunk.get(2).unwrap_or(&0);
        result.push(DIGITS[(first >> 2) as usize] as char);
        result.push(DIGITS[(((first & 3) << 4) | (second >> 4)) as usize] as char);
        result.push(if chunk.len() > 1 {
            DIGITS[(((second & 15) << 2) | (third >> 6)) as usize] as char
        } else {
            '='
        });
        result.push(if chunk.len() > 2 {
            DIGITS[(third & 63) as usize] as char
        } else {
            '='
        });
    }
    result
}

/// app is a catalogue ID; parsing is obtained through Catalogue::icon_source.
/// The PNG response is <=512KiB and fits the existing 1MiB guest header limit.
pub fn extract(app: &str, parsing: &str) -> Result<Value, String> {
    if app.len() != 64
        || parsing.is_empty()
        || parsing.len() > 32768
        || parsing.contains('\0')
        || app != format!("{:x}", Sha256::digest(parsing.as_bytes()))
    {
        return Err("The application icon identity is invalid".into());
    }
    unsafe {
        CoInitializeEx(None, COINIT_APARTMENTTHREADED)
            .ok()
            .map_err(at("COM.Initialize"))?;
        let _apartment = Apartment;
        let item = shell_item(parsing)?;
        let images: IShellItemImageFactory = item.cast().map_err(at("ImageFactory"))?;
        // ICONONLY obtains the app icon for packaged applications and links,
        // never a document preview. Without SCALEUP, small assets stay honest.
        let bitmap = Bitmap(
            images
                .GetImage(
                    SIZE {
                        cx: ICON_EDGE as i32,
                        cy: ICON_EDGE as i32,
                    },
                    SIIGBF_ICONONLY,
                )
                .map_err(at("GetImage"))?,
        );
        let factory: IWICImagingFactory =
            CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)
                .map_err(at("WIC.CreateFactory"))?;
        let source = factory
            .CreateBitmapFromHBITMAP(
                bitmap.0,
                HPALETTE::default(),
                WICBitmapUsePremultipliedAlpha,
            )
            .map_err(at("WIC.CreateBitmapFromHBITMAP"))?;
        let (mut width, mut height) = (0, 0);
        source
            .GetSize(&mut width, &mut height)
            .map_err(at("WIC.GetSize"))?;
        if width == 0 || height == 0 || width > ICON_EDGE || height > ICON_EDGE {
            return Err("The Windows icon exceeds the requested dimensions".into());
        }
        // PNG stores straight alpha; explicitly convert the Shell bitmap's
        // premultiplied pixels instead of changing the encoder's alpha format.
        let straight = factory
            .CreateFormatConverter()
            .map_err(at("WIC.CreateConverter"))?;
        straight
            .Initialize(
                &source,
                &GUID_WICPixelFormat32bppBGRA,
                WICBitmapDitherTypeNone,
                None,
                0.0,
                WICBitmapPaletteTypeCustom,
            )
            .map_err(at("WIC.ConvertAlpha"))?;
        let stream = SHCreateMemStream(None).ok_or("App icon WIC.CreateStream: out of memory")?;
        let encoder = factory
            .CreateEncoder(&GUID_ContainerFormatPng, &GUID_VendorMicrosoft)
            .map_err(at("WIC.CreatePNGEncoder"))?;
        encoder
            .Initialize(&stream, WICBitmapEncoderNoCache)
            .map_err(at("WIC.InitializeEncoder"))?;
        let mut frame: Option<IWICBitmapFrameEncode> = None;
        encoder
            .CreateNewFrame(&mut frame, std::ptr::null_mut())
            .map_err(at("WIC.CreateFrame"))?;
        let frame = frame.ok_or("Cannot create an icon PNG frame")?;
        frame.Initialize(None).map_err(at("WIC.InitializeFrame"))?;
        frame.SetSize(width, height).map_err(at("WIC.SetSize"))?;
        let mut format = GUID_WICPixelFormat32bppBGRA;
        frame
            .SetPixelFormat(&mut format)
            .map_err(at("WIC.SetPixelFormat"))?;
        if format != GUID_WICPixelFormat32bppBGRA {
            return Err("PNG alpha format is unavailable".into());
        }
        frame
            .WriteSource(&straight, std::ptr::null())
            .map_err(at("WIC.WriteSource"))?;
        frame.Commit().map_err(at("WIC.CommitFrame"))?;
        encoder.Commit().map_err(at("WIC.CommitPNG"))?;
        let mut stat = STATSTG::default();
        stream
            .Stat(&mut stat, STATFLAG_NONAME)
            .map_err(at("WIC.StreamStat"))?;
        if stat.cbSize == 0 || stat.cbSize > PNG_LIMIT {
            return Err("The icon PNG exceeds its payload limit".into());
        }
        let mut png = vec![0; stat.cbSize as usize];
        stream
            .Seek(0, STREAM_SEEK_SET, None)
            .map_err(at("WIC.StreamSeek"))?;
        let mut read = 0;
        stream
            .Read(png.as_mut_ptr().cast(), png.len() as u32, Some(&mut read))
            .ok()
            .map_err(at("WIC.StreamRead"))?;
        if read as usize != png.len() {
            return Err("The icon PNG is incomplete".into());
        }
        Ok(
            json!({"app":app,"pngBase64":base64(&png),"width":width,"height":height,
            "sha256":format!("{:x}", Sha256::digest(&png))}),
        )
    }
}
