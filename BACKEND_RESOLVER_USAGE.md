# BackendResolver - Guia de Uso

## Visão Geral

`BackendResolver` é um componente do MTK que verifica a disponibilidade do Metal runtime no sistema e persiste as preferências de backend em UserDefaults.

## Localização

- **Arquivo**: `Sources/MTKCore/Support/BackendResolver.swift`
- **Módulo**: MTKCore
- **Exportação Pública**: Sim

## API

### Enum: BackendResolutionError

Erros que podem ocorrer durante a resolução do backend:

```swift
public enum BackendResolutionError: LocalizedError, Equatable {
    case metalUnavailable
    case noBackendAvailable
}
```

- `metalUnavailable`: Metal runtime não está disponível no sistema
- `noBackendAvailable`: Nenhum backend disponível (reservado para futuras extensões)

### Struct: BackendResolver

#### Inicialização

```swift
// Com UserDefaults para persistência
let resolver = BackendResolver(defaults: UserDefaults.standard)

// Sem persistência (para testes)
let resolver = BackendResolver()
let resolver = BackendResolver(defaults: nil)
```

#### Métodos de Instância

##### checkMetalAvailability() throws -> Bool

Verifica se Metal está disponível e opcionalmente persiste o resultado.

```swift
let resolver = BackendResolver(defaults: UserDefaults.standard)
do {
    let isAvailable = try resolver.checkMetalAvailability()
    print("Metal is available: \(isAvailable)")
} catch BackendResolutionError.metalUnavailable {
    print("Metal runtime not available")
}
```

##### isMetalAvailable() -> Bool

Verifica se Metal está disponível (sem lançar exceção).

```swift
let resolver = BackendResolver()
if resolver.isMetalAvailable() {
    // Use Metal-based rendering
} else {
    // Fallback to alternative rendering
}
```

#### Métodos Estáticos

##### BackendResolver.checkConfiguredMetalAvailability(defaults:) throws -> Bool

Verifica Metal com UserDefaults padrão e persiste resultado.

```swift
do {
    _ = try BackendResolver.checkConfiguredMetalAvailability()
} catch {
    print("Metal check failed: \(error)")
}
```

##### BackendResolver.isMetalAvailable() -> Bool

Verifica Metal sem persistência, sem exceções.

```swift
if BackendResolver.isMetalAvailable() {
    // Metal is available
}
```

#### Constantes

```swift
// UserDefaults key para armazenar resultado da verificação
BackendResolver.metalAvailabilityKey // "volumetric.metalAvailable"

// UserDefaults key para armazenar preferência de backend
BackendResolver.preferredBackendKey // "volumetric.preferredBackend"
```

## Exemplos de Uso

### Exemplo 1: Verificação Simples

```swift
let resolver = BackendResolver()
if resolver.isMetalAvailable() {
    print("Metal rendering available")
} else {
    print("Metal rendering unavailable")
}
```

### Exemplo 2: Verificação com Persistência

```swift
let resolver = BackendResolver(defaults: UserDefaults.standard)

do {
    _ = try resolver.checkMetalAvailability()
    print("Metal availability persisted to UserDefaults")
} catch BackendResolutionError.metalUnavailable {
    print("Metal not available")
}
```

### Exemplo 3: Integração com Inicialização de Aplicativo

```swift
@main
struct MyApp: App {
    init() {
        // Check Metal availability during app launch
        if !BackendResolver.isMetalAvailable() {
            print("Warning: Metal runtime not available. Using fallback rendering.")
        }
    }

    var body: some Scene {
        // App UI
    }
}
```

### Exemplo 4: Testes Unitários

```swift
import XCTest

class BackendResolverTests: XCTestCase {
    func testMetalAvailabilityWithoutPersistence() {
        let resolver = BackendResolver(defaults: nil)

        // No side effects
        let available = resolver.isMetalAvailable()

        XCTAssertFalse(available) // Will depend on system
    }

    func testMetalAvailabilityWithPersistence() {
        let defaults = UserDefaults(suiteName: "test")!
        let resolver = BackendResolver(defaults: defaults)

        do {
            _ = try resolver.checkMetalAvailability()
        } catch {
            // Metal not available on test system
        }
    }
}
```

## Integração com VolumetricSessionState (Isis)

O BackendResolver pode ser integrado no Isis DICOM Viewer para centralizar a lógica de resolução de backend:

```swift
// Em VolumetricSessionState.swift
static func selectConfiguredBackend(defaults: UserDefaults = .standard) throws -> VolumetricRenderingBackend {
    // Use MTK's BackendResolver to check Metal availability
    let resolver = BackendResolver(defaults: defaults)

    do {
        _ = try resolver.checkMetalAvailability()
        return .metalPerformanceShaders
    } catch BackendResolutionError.metalUnavailable {
        throw VolumetricSessionState.RuntimeError.metalUnavailable
    }
}
```

## Arquitetura

### Dependências

- `Foundation` - UserDefaults, error handling
- `MetalRuntimeAvailability` (condicional) - Metal availability bridge
- `MetalRuntimeGuard` (condicional) - Suporte runtime do MTK

### Sem Dependências De

- MTKUI (evita circular dependency)
- VolumetricSceneController
- Isis DICOM Viewer

### Condicional Compilation

O BackendResolver usa compilação condicional para suportar múltiplas plataformas:

```swift
#if canImport(MetalAdapters)
    return MetalRuntimeAvailability.isAvailable()
#else
    return false
#endif
```

## Testabilidade

BackendResolver é altamente testável:

1. **Sem Persistência**: Crie instâncias com `defaults: nil`
2. **Mock UserDefaults**: Use `UserDefaults(suiteName:)` para testes
3. **Sem Efeitos Colaterais**: O método `isMetalAvailable()` não persiste
4. **Mensagens de Erro Claras**: ErrorDescription e failureReason

## Migração do Isis

Para migrar o BackendResolver do Isis DICOM Viewer para usar este módulo MTK:

1. Remover a struct `BackendResolver` de `VolumetricSessionState.swift`
2. Importar `MTKCore` no módulo Isis
3. Usar `BackendResolver` do MTK diretamente
4. Adaptar erros conforme necessário (mapeiar `BackendResolutionError` para `VolumetricSessionState.RuntimeError`)

Exemplo:

```swift
// Antes (Isis)
struct BackendResolver {
    let defaults: UserDefaults
    func resolve() throws -> VolumetricRenderingBackend { ... }
}

// Depois (com MTK)
import MTKCore

let mtkResolver = BackendResolver(defaults: defaults)
if try mtkResolver.checkMetalAvailability() {
    // Metal is available
}
```

## Notas

- BackendResolver foi extraído da classe VolumetricSessionState do Isis DICOM Viewer
- A implementação no MTK é refatorada para evitar dependências circulares
- Foca especificamente em verificação de disponibilidade Metal
- A resolução de backend específico (SceneKit vs Metal) é responsabilidade de camadas superiores
