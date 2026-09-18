import SwiftUI
import LightStarCore

/// Keyboard view for remote text input and key commands to Mac.
struct RemoteKeyboardView: View {
    @ObservedObject var client: RemoteControlClient
    @State private var textInput = ""
    @State private var showingKeyboard = false
    @FocusState private var isTextFieldFocused: Bool
    
    // Modifier key states
    @State private var commandPressed = false
    @State private var optionPressed = false
    @State private var controlPressed = false
    @State private var shiftPressed = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    textInputSection
                    modifierKeysSection
                    commonKeysSection
                    mediaKeysSection
                    functionKeysSection
                }
                .padding()
            }
            .navigationTitle("Keyboard")
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }
    
    // MARK: - Text Input
    
    private var textInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Text Input")
                .font(.headline)
            
            HStack {
                TextField("Type here...", text: $textInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        sendText()
                    }
                
                Button("Send") {
                    sendText()
                }
                .buttonStyle(.borderedProminent)
                .disabled(textInput.isEmpty)
            }
            
            Text("Text is sent to Mac when you tap Send or press Return")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    private func sendText() {
        guard !textInput.isEmpty else { return }
        client.sendTextInput(textInput)
        textInput = ""
    }
    
    // MARK: - Modifier Keys
    
    private var modifierKeysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Modifier Keys")
                .font(.headline)
            
            HStack(spacing: 12) {
                ModifierKeyButton(
                    title: "⌘",
                    subtitle: "Cmd",
                    isPressed: $commandPressed,
                    action: { sendModifierKey(.command) }
                )
                
                ModifierKeyButton(
                    title: "⌥",
                    subtitle: "Opt",
                    isPressed: $optionPressed,
                    action: { sendModifierKey(.option) }
                )
                
                ModifierKeyButton(
                    title: "⌃",
                    subtitle: "Ctrl",
                    isPressed: $controlPressed,
                    action: { sendModifierKey(.control) }
                )
                
                ModifierKeyButton(
                    title: "⇧",
                    subtitle: "Shift",
                    isPressed: $shiftPressed,
                    action: { sendModifierKey(.shift) }
                )
            }
            
            Text("Tap to toggle, then tap another key to send combination")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    private func sendModifierKey(_ modifier: ModifierType) {
        switch modifier {
        case .command: commandPressed.toggle()
        case .option: optionPressed.toggle()
        case .control: controlPressed.toggle()
        case .shift: shiftPressed.toggle()
        }
    }
    
    private enum ModifierType {
        case command, option, control, shift
    }
    
    // MARK: - Common Keys
    
    private var commonKeysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Common Keys")
                .font(.headline)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                KeyButton(title: "Esc", icon: nil) {
                    sendKey(keyCode: 0x35)
                }
                
                KeyButton(title: "Tab", icon: nil) {
                    sendKey(keyCode: 0x30)
                }
                
                KeyButton(title: "Delete", icon: "delete.left") {
                    sendKey(keyCode: 0x33)
                }
                
                KeyButton(title: "Return", icon: "return") {
                    sendKey(keyCode: 0x24)
                }
                
                KeyButton(title: "Space", icon: nil) {
                    sendKey(keyCode: 0x31)
                }
                
                KeyButton(title: "←", icon: nil) {
                    sendKey(keyCode: 0x7B)
                }
                
                KeyButton(title: "→", icon: nil) {
                    sendKey(keyCode: 0x7C)
                }
                
                KeyButton(title: "↑", icon: nil) {
                    sendKey(keyCode: 0x7E)
                }
                
                KeyButton(title: "↓", icon: nil) {
                    sendKey(keyCode: 0x7D)
                }
                
                KeyButton(title: "Home", icon: nil) {
                    sendKey(keyCode: 0x73)
                }
                
                KeyButton(title: "End", icon: nil) {
                    sendKey(keyCode: 0x77)
                }
                
                KeyButton(title: "PgUp", icon: nil) {
                    sendKey(keyCode: 0x74)
                }
                
                KeyButton(title: "PgDn", icon: nil) {
                    sendKey(keyCode: 0x79)
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Media Keys
    
    private var mediaKeysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Media Controls")
                .font(.headline)
            
            HStack(spacing: 12) {
                KeyButton(title: nil, icon: "backward.fill") {
                    client.sendMediaKey(.previousTrack)
                }
                
                KeyButton(title: nil, icon: "playpause.fill") {
                    client.sendMediaKey(.playPause)
                }
                
                KeyButton(title: nil, icon: "forward.fill") {
                    client.sendMediaKey(.nextTrack)
                }
                
                Spacer()
                
                KeyButton(title: nil, icon: "speaker.slash.fill") {
                    client.sendMediaKey(.mute)
                }
                
                KeyButton(title: nil, icon: "speaker.minus.fill") {
                    client.sendMediaKey(.volumeDown)
                }
                
                KeyButton(title: nil, icon: "speaker.plus.fill") {
                    client.sendMediaKey(.volumeUp)
                }
            }
            
            HStack(spacing: 12) {
                KeyButton(title: nil, icon: "sun.min") {
                    client.sendMediaKey(.brightnessDown)
                }
                
                KeyButton(title: nil, icon: "sun.max") {
                    client.sendMediaKey(.brightnessUp)
                }
                
                Spacer()
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Function Keys
    
    private var functionKeysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Function Keys")
                .font(.headline)
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                ForEach(1...12, id: \.self) { num in
                    KeyButton(title: "F\(num)", icon: nil) {
                        sendFunctionKey(num)
                    }
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Key Sending
    
    private func sendKey(keyCode: UInt16) {
        var modifiers: UInt32 = 0
        if commandPressed { modifiers |= 0x100000 }  // CGEventFlags.maskCommand
        if optionPressed { modifiers |= 0x80000 }    // CGEventFlags.maskAlternate
        if controlPressed { modifiers |= 0x40000 }   // CGEventFlags.maskControl
        if shiftPressed { modifiers |= 0x20000 }     // CGEventFlags.maskShift
        
        client.sendKeyDown(keyCode: keyCode, modifiers: modifiers)
        client.sendKeyUp(keyCode: keyCode, modifiers: modifiers)
        
        // Reset modifier states after sending
        commandPressed = false
        optionPressed = false
        controlPressed = false
        shiftPressed = false
    }
    
    private func sendFunctionKey(_ num: Int) {
        let keyCodes: [Int: UInt16] = [
            1: 0x7A, 2: 0x78, 3: 0x63, 4: 0x76,
            5: 0x60, 6: 0x61, 7: 0x62, 8: 0x64,
            9: 0x65, 10: 0x6D, 11: 0x67, 12: 0x6F
        ]
        if let keyCode = keyCodes[num] {
            sendKey(keyCode: keyCode)
        }
    }
}

// MARK: - Key Button Component

struct KeyButton: View {
    let title: String?
    let icon: String?
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Group {
                if let icon = icon {
                    Image(systemName: icon)
                } else if let title = title {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Modifier Key Button

struct ModifierKeyButton: View {
    let title: String
    let subtitle: String
    @Binding var isPressed: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
        }
        .buttonStyle(isPressed ? .borderedProminent : .bordered)
    }
}

// MARK: - Shortcut Buttons

struct ShortcutButton: View {
    let title: String
    let keys: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                Text(keys)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(.bordered)
    }
}

#Preview {
    RemoteKeyboardView(client: RemoteControlClient())
}
