import SwiftUI
import LightStarCore

/// Compact Mac modifier row that sits above the system keyboard — not inside `.toolbar(.keyboard)`,
/// which overflows into a single tinted capsule on iPhone.
struct MacKeyboardAccessory: View {
    @Binding var commandHeld: Bool
    @Binding var optionHeld: Bool
    @Binding var controlHeld: Bool
    @Binding var shiftHeld: Bool
    var hapticsEnabled = true
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            modifierChip("⌘", name: "Command", isOn: $commandHeld)
            modifierChip("⌥", name: "Option", isOn: $optionHeld)
            modifierChip("⌃", name: "Control", isOn: $controlHeld)
            modifierChip("⇧", name: "Shift", isOn: $shiftHeld)
            Button(action: onDismiss) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            .buttonStyle(RemotePressButtonStyle())
            .accessibilityLabel("Hide keyboard")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func modifierChip(_ symbol: String, name: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            RemoteHaptics.select(enabled: hapticsEnabled)
        } label: {
            Text(symbol)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isOn.wrappedValue ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.12))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isOn.wrappedValue ? Color.accentColor : Color.clear, lineWidth: 1)
                }
        }
        .buttonStyle(RemotePressButtonStyle())
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }
}

struct RemotePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.16) : Color.clear)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

enum MacHIDKeyCode {
    static func from(_ character: Character) -> UInt16? {
        switch character.lowercased() {
        case "a": return 0x00
        case "s": return 0x01
        case "d": return 0x02
        case "f": return 0x03
        case "h": return 0x04
        case "g": return 0x05
        case "z": return 0x06
        case "x": return 0x07
        case "c": return 0x08
        case "v": return 0x09
        case "b": return 0x0B
        case "q": return 0x0C
        case "w": return 0x0D
        case "e": return 0x0E
        case "r": return 0x0F
        case "y": return 0x10
        case "t": return 0x11
        case "1": return 0x12
        case "2": return 0x13
        case "3": return 0x14
        case "4": return 0x15
        case "6": return 0x16
        case "5": return 0x17
        case "9": return 0x19
        case "7": return 0x1A
        case "8": return 0x1C
        case "0": return 0x1D
        case "o": return 0x1F
        case "u": return 0x20
        case "i": return 0x22
        case "p": return 0x23
        case "l": return 0x25
        case "j": return 0x26
        case "k": return 0x28
        case "n": return 0x2D
        case "m": return 0x2E
        default: return nil
        }
    }
}
