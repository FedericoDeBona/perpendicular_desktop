/// A superseded geometry read may still deliver its reply. Retire the wait
/// once, without cancelling or confusing a subsequent display operation.
@MainActor
final class DesktopResizeRead {
    private var completion:((Bool)->Void)?
    var pending:Bool {completion != nil}
    init(_ completion:@escaping (Bool)->Void){self.completion=completion}
    func finish(_ matched:Bool){
        guard let completion else{return}
        self.completion=nil
        completion(matched)
    }
}
