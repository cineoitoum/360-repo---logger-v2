#if !canImport(SwiftUI)
// A interface é SwiftUI (macOS). Fora do macOS só o núcleo é compilado e testado.
@main
enum UnificadorVRStub {
    static func main() {
        print("Unificador VR: a interface gráfica requer macOS 13 ou superior.")
    }
}
#endif
