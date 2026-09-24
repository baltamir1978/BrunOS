import Compression
import Foundation

/// Comprimir y descomprimir ZIP, **sin dependencias**: el formato a mano y
/// *deflate* con el framework Compression de Apple (`.zlib`, que es *deflate*
/// en crudo, RFC 1951, justo lo que va dentro de un ZIP). Lo pidió Bruno el
/// 24-sep-2026.
///
/// iOS no trae API pública para descomprimir ZIP. Para comprimir hay un
/// atajo (leer una carpeta coordinada con `.forUploading`), pero mete un solo
/// fichero dentro de una carpeta y no da progreso; así, las dos cosas van
/// igual y por trozos, sin cargar ningún fichero entero en memoria.
///
/// **Lo que no**: ZIP64 (ficheros de más de 4 GB o más de 65.535 entradas) y
/// ZIP cifrados. Se dice en vez de fallar a medias.
enum ZipArchive {

    enum ZipError: LocalizedError {
        case tooLarge
        case notAZip
        case encrypted
        case unsupportedMethod(Int)
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge: "El ZIP es demasiado grande: más de 4 GB o de 65.535 ficheros (ZIP64 no está soportado)."
            case .notAZip: "No es un ZIP, o está incompleto."
            case .encrypted: "El ZIP está cifrado con contraseña, y eso no está soportado."
            case .unsupportedMethod(let method): "El ZIP usa una compresión que no se conoce (método \(method))."
            case .corrupt(let name): "El ZIP está dañado en «\(name)»."
            }
        }
    }

    private static let chunk = 256 * 1024

    // MARK: - Comprimir

    /// Comprime ficheros y carpetas en un ZIP nuevo. Cada `source` entra con
    /// su nombre en la raíz del ZIP; las carpetas, con todo lo de dentro.
    /// `onFile` avisa con el nombre de cada fichero al empezarlo.
    static func create(at zip: URL, from sources: [URL], onFile: (String) -> Void = { _ in }) throws {
        var entries: [(url: URL, name: String, isDirectory: Bool)] = []
        for source in sources {
            try collect(source, name: source.lastPathComponent, into: &entries)
        }
        guard entries.count < 65_535 else { throw ZipError.tooLarge }

        FileManager.default.createFile(atPath: zip.path, contents: nil)
        let output = try FileHandle(forWritingTo: zip)
        defer { try? output.close() }

        var central = Data()
        for entry in entries {
            try Task.checkCancellation()
            let offset = try output.offset()
            guard offset < UInt64(UInt32.max) else { throw ZipError.tooLarge }
            onFile(entry.name)

            let modified = (try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            let (time, date) = dosDateTime(modified)
            // Los nombres, en forma compuesta (la ñ como un solo carácter): el
            // sistema los da descompuestos, y otros sistemas no los igualan.
            let name = Data((entry.isDirectory ? entry.name + "/" : entry.name)
                .precomposedStringWithCanonicalMapping.utf8)
            let method: UInt16 = entry.isDirectory ? 0 : 8

            // Cabecera local con el CRC y los tamaños a cero: se rellenan al
            // terminar el fichero, volviendo atrás.
            var header = Data()
            header.append(le32: 0x0403_4b50)
            header.append(le16: 20)
            header.append(le16: 0x0800)          // Nombres en UTF-8.
            header.append(le16: method)
            header.append(le16: time)
            header.append(le16: date)
            header.append(le32: 0)                // CRC-32
            header.append(le32: 0)                // Tamaño comprimido
            header.append(le32: 0)                // Tamaño original
            header.append(le16: UInt16(name.count))
            header.append(le16: 0)
            header.append(name)
            try output.write(contentsOf: header)

            var crc: UInt32 = 0
            var compressed: UInt64 = 0
            var original: UInt64 = 0
            if !entry.isDirectory {
                let input = try FileHandle(forReadingFrom: entry.url)
                defer { try? input.close() }
                var failure: Error?
                let filter = try OutputFilter(.compress, using: .zlib) { data in
                    guard let data, failure == nil else { return }
                    do {
                        try output.write(contentsOf: data)
                        compressed += UInt64(data.count)
                    } catch { failure = error }
                }
                while let block = try input.read(upToCount: chunk), !block.isEmpty {
                    try Task.checkCancellation()
                    crc = CRC32.update(crc, with: block)
                    original += UInt64(block.count)
                    try filter.write(block)
                    if let failure { throw failure }
                }
                try filter.finalize()
                if let failure { throw failure }
            }
            guard compressed < UInt64(UInt32.max), original < UInt64(UInt32.max) else { throw ZipError.tooLarge }

            let end = try output.offset()
            try output.seek(toOffset: offset + 14)
            var sizes = Data()
            sizes.append(le32: crc)
            sizes.append(le32: UInt32(compressed))
            sizes.append(le32: UInt32(original))
            try output.write(contentsOf: sizes)
            try output.seek(toOffset: end)

            central.append(le32: 0x0201_4b50)
            central.append(le16: 0x031E)         // Hecho en Unix, versión 3.0.
            central.append(le16: 20)
            central.append(le16: 0x0800)
            central.append(le16: method)
            central.append(le16: time)
            central.append(le16: date)
            central.append(le32: crc)
            central.append(le32: UInt32(compressed))
            central.append(le32: UInt32(original))
            central.append(le16: UInt16(name.count))
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0)
            // Permisos de Unix arriba (rwxr-xr-x las carpetas, rw-r--r-- los
            // ficheros) y el bit de carpeta de MS-DOS abajo.
            let attributes: UInt32 = entry.isDirectory ? (0o040755 << 16) | 0x10 : (0o100644 << 16)
            central.append(le32: attributes)
            central.append(le32: UInt32(offset))
            central.append(name)
        }

        let centralOffset = try output.offset()
        guard centralOffset < UInt64(UInt32.max) else { throw ZipError.tooLarge }
        try output.write(contentsOf: central)

        var end = Data()
        end.append(le32: 0x0605_4b50)
        end.append(le16: 0)
        end.append(le16: 0)
        end.append(le16: UInt16(entries.count))
        end.append(le16: UInt16(entries.count))
        end.append(le32: UInt32(central.count))
        end.append(le32: UInt32(centralOffset))
        end.append(le16: 0)
        try output.write(contentsOf: end)
    }

    /// Recorre una carpeta: primero ella, luego lo de dentro.
    private static func collect(
        _ url: URL,
        name: String,
        into entries: inout [(url: URL, name: String, isDirectory: Bool)]
    ) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        entries.append((url, name, isDirectory.boolValue))
        guard isDirectory.boolValue else { return }
        let children = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            try collect(child, name: name + "/" + child.lastPathComponent, into: &entries)
        }
    }

    // MARK: - Descomprimir

    /// Cuántos ficheros trae un ZIP, para la barra de progreso.
    static func entryCount(_ zip: URL) throws -> Int {
        try readDirectory(zip).filter { !$0.isDirectory }.count
    }

    /// Descomprime un ZIP en una carpeta, que tiene que existir.
    static func extract(_ zip: URL, into destination: URL, onFile: (String) -> Void = { _ in }) throws {
        let entries = try readDirectory(zip)
        let input = try FileHandle(forReadingFrom: zip)
        defer { try? input.close() }

        for entry in entries {
            try Task.checkCancellation()
            guard let relative = safePath(entry.name) else { continue }
            let target = destination.appending(path: relative)

            if entry.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            onFile((relative as NSString).lastPathComponent)
            guard entry.flags & 1 == 0 else { throw ZipError.encrypted }
            guard entry.method == 0 || entry.method == 8 else { throw ZipError.unsupportedMethod(Int(entry.method)) }

            // Dónde empiezan los datos: la cabecera local puede llevar un
            // «extra» distinto del del índice.
            try input.seek(toOffset: entry.localOffset)
            guard let local = try input.read(upToCount: 30), local.count == 30,
                  local.le32(at: 0) == 0x0403_4b50
            else { throw ZipError.corrupt(entry.name) }
            let dataOffset = entry.localOffset + 30 + UInt64(local.le16(at: 26)) + UInt64(local.le16(at: 28))

            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: target.path, contents: nil)
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }

            try input.seek(toOffset: dataOffset)
            var remaining = entry.compressedSize
            var crc: UInt32 = 0
            var failure: Error?
            let write: (Data) -> Void = { data in
                guard failure == nil else { return }
                do {
                    try output.write(contentsOf: data)
                    crc = CRC32.update(crc, with: data)
                } catch { failure = error }
            }
            let filter = entry.method == 8
                ? try OutputFilter(.decompress, using: .zlib) { data in if let data { write(data) } }
                : nil
            while remaining > 0 {
                try Task.checkCancellation()
                let size = Int(min(UInt64(chunk), remaining))
                guard let block = try input.read(upToCount: size), !block.isEmpty else {
                    throw ZipError.corrupt(entry.name)
                }
                remaining -= UInt64(block.count)
                if let filter { try filter.write(block) } else { write(block) }
                if let failure { throw failure }
            }
            try filter?.finalize()
            if let failure { throw failure }
            guard crc == entry.crc else { throw ZipError.corrupt(entry.name) }
        }
    }

    private struct Entry {
        var name: String
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var localOffset: UInt64
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    /// El índice del final del ZIP: qué hay y dónde empieza cada cosa.
    private static func readDirectory(_ zip: URL) throws -> [Entry] {
        let input = try FileHandle(forReadingFrom: zip)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        guard size >= 22 else { throw ZipError.notAZip }

        // El final del índice está en los últimos 22 bytes más el comentario,
        // que como mucho mide 64 KB.
        let tail = min(size, 22 + 65_535)
        try input.seek(toOffset: size - tail)
        guard let data = try input.read(upToCount: Int(tail)) else { throw ZipError.notAZip }
        var endIndex: Int?
        var index = data.count - 22
        while index >= 0 {
            if data.le32(at: index) == 0x0605_4b50 { endIndex = index; break }
            index -= 1
        }
        guard let end = endIndex else { throw ZipError.notAZip }
        let count = Int(data.le16(at: end + 10))
        let centralSize = UInt64(data.le32(at: end + 12))
        let centralOffset = UInt64(data.le32(at: end + 16))
        guard count != 0xFFFF, centralOffset != 0xFFFF_FFFF else { throw ZipError.tooLarge }
        guard centralOffset + centralSize <= size else { throw ZipError.notAZip }

        try input.seek(toOffset: centralOffset)
        guard let central = try input.read(upToCount: Int(centralSize)) else { throw ZipError.notAZip }
        var entries: [Entry] = []
        var cursor = 0
        for _ in 0..<count {
            guard cursor + 46 <= central.count, central.le32(at: cursor) == 0x0201_4b50 else {
                throw ZipError.notAZip
            }
            let flags = central.le16(at: cursor + 8)
            let nameLength = Int(central.le16(at: cursor + 28))
            let extraLength = Int(central.le16(at: cursor + 30))
            let commentLength = Int(central.le16(at: cursor + 32))
            guard cursor + 46 + nameLength <= central.count else { throw ZipError.notAZip }
            let nameData = central.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            // Sin la marca de UTF-8, el ZIP va en CP437; casi siempre es ASCII
            // y Latin-1 lo lee bien, y si no, algo legible.
            let name = flags & 0x0800 != 0
                ? String(decoding: nameData, as: UTF8.self)
                : String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? "?"
            let compressed = UInt64(central.le32(at: cursor + 20))
            let localOffset = UInt64(central.le32(at: cursor + 42))
            guard compressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else { throw ZipError.tooLarge }
            entries.append(Entry(
                name: name,
                flags: flags,
                method: central.le16(at: cursor + 10),
                crc: central.le32(at: cursor + 16),
                compressedSize: compressed,
                localOffset: localOffset
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// La ruta de una entrada, **sin poder salirse de la carpeta de destino**:
    /// un ZIP malicioso puede traer `../../algo` para escribir fuera. También
    /// fuera los `__MACOSX` y `.DS_Store` que mete el Finder.
    private static func safePath(_ name: String) -> String? {
        let parts = name.split(separator: "/").filter { !$0.isEmpty && $0 != "." }
        guard !parts.isEmpty, !parts.contains(".."),
              parts.first != "__MACOSX", parts.last != ".DS_Store"
        else { return nil }
        // En forma compuesta: el Finder guarda la ñ como «n» más la tilde.
        return parts.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    /// Fecha y hora en el formato de MS-DOS que usa el ZIP.
    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let year = max(0, (parts.year ?? 1980) - 1980)
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }
}

/// El CRC-32 del ZIP (el de siempre, polinomio 0xEDB88320), por trozos.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func update(_ crc: UInt32, with data: Data) -> UInt32 {
        var value = ~crc
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
            }
        }
        return ~value
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func le16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func le32(at offset: Int) -> UInt32 {
        UInt32(le16(at: offset)) | UInt32(le16(at: offset + 2)) << 16
    }
}
