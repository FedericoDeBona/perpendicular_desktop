import AppKit

/// A sibling of the Metal view, so the waiting UI never depends on guest pixels.
@MainActor
final class WindowTransitionView:NSVisualEffectView {
    private let icon=NSImageView()
    private let ring=WaitingRing(frame:.zero)
    private let title=NSTextField(labelWithString:"App Windows")
    private let detail=NSTextField(labelWithString:"Preparazione della finestra…")
    private let recoveryButton=NSButton(title:"Apri Windows",target:nil,action:nil)
    private let revealButton=NSButton(title:"Mostra comunque",target:nil,action:nil)
    private let actions=NSStackView()
    var recovery:(()->Void)?
    var reveal:(()->Void)?

    override init(frame:NSRect){
        super.init(frame:frame)
        material = .hudWindow;blendingMode = .withinWindow;state = .active
        wantsLayer=true;layer?.cornerRadius=10;layer?.masksToBounds=true
        let veil=NSView();veil.wantsLayer=true
        veil.layer?.backgroundColor=NSColor.windowBackgroundColor.withAlphaComponent(
            NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1:0.86).cgColor
        veil.translatesAutoresizingMaskIntoConstraints=false;addSubview(veil)
        NSLayoutConstraint.activate([veil.leadingAnchor.constraint(equalTo:leadingAnchor),
            veil.trailingAnchor.constraint(equalTo:trailingAnchor),veil.topAnchor.constraint(equalTo:topAnchor),
            veil.bottomAnchor.constraint(equalTo:bottomAnchor)])
        icon.image=NSImage(systemSymbolName:"macwindow",accessibilityDescription:"App Windows")
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer=true;icon.layer?.shadowOpacity=0.12;icon.layer?.shadowRadius=8
        title.font = .systemFont(ofSize:15,weight:.semibold)
        title.lineBreakMode = .byTruncatingTail;title.alignment = .center
        detail.font = .systemFont(ofSize:12);detail.textColor = .secondaryLabelColor
        detail.alignment = .center;detail.lineBreakMode = .byTruncatingTail
        recoveryButton.target=self;recoveryButton.action=#selector(openRecovery)
        revealButton.target=self;revealButton.action=#selector(showContent)
        for button in [recoveryButton,revealButton] {button.bezelStyle = .rounded;button.controlSize = .small}
        actions.orientation = .horizontal;actions.spacing=8
        actions.addArrangedSubview(recoveryButton);actions.addArrangedSubview(revealButton);actions.isHidden=true
        let stack=NSStackView(views:[icon,ring,title,detail,actions])
        stack.orientation = .vertical;stack.alignment = .centerX;stack.spacing=10
        stack.setCustomSpacing(4,after:title);stack.translatesAutoresizingMaskIntoConstraints=false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo:centerXAnchor),
            stack.centerYAnchor.constraint(equalTo:centerYAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo:widthAnchor,constant:-32),
            detail.widthAnchor.constraint(lessThanOrEqualTo:widthAnchor,constant:-32),
            icon.widthAnchor.constraint(equalToConstant:56),icon.heightAnchor.constraint(equalToConstant:56),
            ring.widthAnchor.constraint(equalToConstant:24),ring.heightAnchor.constraint(equalToConstant:24)])
        setAccessibilityRole(.group);setAccessibilityLabel("Preparazione della finestra")
        isHidden=true
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func identify(name:String,icon:NSImage?){
        title.stringValue=name
        if let icon {self.icon.image=icon}
    }
    func begin(_ message:String){
        layer?.removeAllAnimations();alphaValue=1;isHidden=false
        detail.stringValue=message;actions.isHidden=true;ring.isHidden=false;ring.start()
        setAccessibilityLabel(message)
    }
    func stalled(_ message:String,canReveal:Bool){
        detail.stringValue=message;ring.stop();ring.isHidden=true
        revealButton.isHidden = !canReveal;actions.isHidden=false
        setAccessibilityLabel(message)
    }
    func finish(completed:@escaping @MainActor @Sendable ()->Void){
        ring.stop()
        NSAnimationContext.runAnimationGroup({context in
            context.duration=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0:0.16
            self.animator().alphaValue=0
        },completionHandler:{Task{@MainActor in completed()}})
    }
    @objc private func openRecovery(){recovery?()}
    @objc private func showContent(){reveal?()}
    override func resetCursorRects(){addCursorRect(bounds,cursor:.arrow)}
}

@MainActor
private final class WaitingRing:NSView {
    private let stroke=CAShapeLayer()
    override init(frame:NSRect){
        super.init(frame:frame);wantsLayer=true;layer?.addSublayer(stroke)
        stroke.fillColor=nil;stroke.lineWidth=2.3;stroke.lineCap = .round
        stroke.strokeStart=0.02;stroke.strokeEnd=0.76
        setAccessibilityRole(.progressIndicator);setAccessibilityLabel("Attesa")
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    override func layout(){
        super.layout();stroke.frame=bounds
        stroke.path=CGPath(ellipseIn:bounds.insetBy(dx:2,dy:2),transform:nil)
        stroke.strokeColor=NSColor.labelColor.cgColor
    }
    func start(){
        stop()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else{return}
        let rotation=CABasicAnimation(keyPath:"transform.rotation.z")
        rotation.fromValue=0;rotation.toValue = -Double.pi*2;rotation.duration=1.05;rotation.repeatCount = .infinity
        stroke.add(rotation,forKey:"turn")
        let sweep=CAKeyframeAnimation(keyPath:"strokeEnd")
        sweep.values=[0.18,0.82,0.18];sweep.keyTimes=[0,0.5,1]
        sweep.duration=1.6;sweep.repeatCount = .infinity
        sweep.timingFunctions=[CAMediaTimingFunction(name:.easeInEaseOut),CAMediaTimingFunction(name:.easeInEaseOut)]
        stroke.add(sweep,forKey:"sweep")
    }
    func stop(){stroke.removeAllAnimations()}
}
