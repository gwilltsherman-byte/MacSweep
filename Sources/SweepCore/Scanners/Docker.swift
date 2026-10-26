import Foundation

public struct DockerImage: Sendable, Hashable {
    public var id: String
    public var repository: String
    public var tag: String
    public var size: Int64?
    public var created: String
    public var dangling: Bool { repository == "<none>" }
}

public struct DockerContainer: Sendable, Hashable {
    public var id: String
    public var name: String
    public var image: String
    public var status: String
    public var size: Int64?
}

public struct DockerSnapshot: Sendable {
    public var docker: String
    public var running: Bool
    public var images: [DockerImage] = []
    public var containers: [DockerContainer] = []
    public var danglingVolumes: [String] = []
    public var buildCache: Int64?
}

public enum Docker {
    static func snapshot(shell: Shell) async -> DockerSnapshot? {
        guard let docker = shell.which("docker") else { return nil }
        let info = await shell.run(docker, ["info", "--format", "{{.ServerVersion}}"], timeout: 15)
        guard info.ok else { return DockerSnapshot(docker: docker, running: false) }
        async let images = shell.run(docker, ["image", "ls", "--format", "{{json .}}"], timeout: 60)
        async let containers = shell.run(docker, ["ps", "-a", "-s", "--filter", "status=exited", "--filter", "status=created",
                                                  "--filter", "status=dead", "--format", "{{json .}}"], timeout: 120)
        async let volumes = shell.run(docker, ["volume", "ls", "--filter", "dangling=true", "--format", "{{json .}}"], timeout: 60)
        async let df = shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 120)
        var snapshot = DockerSnapshot(docker: docker, running: true)
        snapshot.images = parseImages(await images.stdout)
        snapshot.containers = parseContainers(await containers.stdout)
        snapshot.danglingVolumes = jsonLines(await volumes.stdout).compactMap { $0["Name"] as? String }
        snapshot.buildCache = parseBuildCache(await df.stdout)
        return snapshot
    }

    static func jsonLines(_ text: String) -> [[String: Any]] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    public static func parseImages(_ text: String) -> [DockerImage] {
        jsonLines(text).compactMap { row in
            guard let id = row["ID"] as? String else { return nil }
            return DockerImage(id: id, repository: row["Repository"] as? String ?? "<none>", tag: row["Tag"] as? String ?? "",
                               size: (row["Size"] as? String).flatMap(SizeParser.parse),
                               created: row["CreatedSince"] as? String ?? "")
        }
    }

    public static func parseContainers(_ text: String) -> [DockerContainer] {
        jsonLines(text).compactMap { row in
            guard let id = row["ID"] as? String else { return nil }
            // "Size" looks like "12.3kB (virtual 1.2GB)"; the first number is what the container itself uses.
            let sizeText = (row["Size"] as? String)?.split(separator: "(").first.map(String.init) ?? ""
            return DockerContainer(id: id, name: row["Names"] as? String ?? id, image: row["Image"] as? String ?? "",
                                   status: row["Status"] as? String ?? "", size: SizeParser.parse(sizeText))
        }
    }

    public static func parseBuildCache(_ text: String) -> Int64? {
        for row in jsonLines(text) where (row["Type"] as? String) == "Build Cache" {
            let reclaimable = (row["Reclaimable"] as? String)?.split(separator: " ").first.map(String.init) ?? ""
            return SizeParser.parse(reclaimable) ?? (row["Size"] as? String).flatMap(SizeParser.parse)
        }
        return nil
    }

    static func scan(_ ctx: ScanContext) async -> ScanResult {
        let id = "docker"
        var items: [Item] = []
        var notes: [String] = []

        if let snap = await ctx.docker() {
            if !snap.running {
                notes.append("Docker is installed but not running. Start it to see images, containers and volumes.")
            }
            for image in snap.images {
                let name = image.dangling ? "Untagged image \(image.id.prefix(12))" : "\(image.repository):\(image.tag)"
                items.append(Item(
                    id: "\(id)|image|\(image.id)|\(image.repository):\(image.tag)", categoryID: id, title: name,
                    detail: "Docker image · created \(image.created)", size: image.size,
                    risk: image.dangling ? .safe : .review,
                    note: image.dangling
                        ? "A leftover layer from an old build that no tag points to."
                        : "Pulled again automatically the next time something needs it. Sizes overlap when images share layers.",
                    badges: image.dangling ? ["Dangling"] : [],
                    steps: [.run(ShellCommand(snap.docker, ["image", "rm"],
                                              targets: [image.dangling ? image.id : "\(image.repository):\(image.tag)"],
                                              batchable: true))]
                ))
            }
            for container in snap.containers {
                items.append(Item(
                    id: "\(id)|container|\(container.id)", categoryID: id, title: "Container \(container.name)",
                    detail: "\(container.image) · \(container.status)", size: container.size, risk: .review,
                    note: "A stopped container. Anything written inside it (outside volumes) is lost when it's removed.",
                    badges: ["Stopped"],
                    steps: [.run(ShellCommand(snap.docker, ["rm"], targets: [container.id], batchable: true))]
                ))
            }
            for volume in snap.danglingVolumes {
                items.append(Item(
                    id: "\(id)|volume|\(volume)", categoryID: id, title: "Volume \(volume)", detail: "Not used by any container",
                    risk: .caution, note: "Volumes hold data such as databases. This one isn't attached to any container, but its data is gone for good once removed.",
                    badges: ["Unused volume"],
                    steps: [.run(ShellCommand(snap.docker, ["volume", "rm"], targets: [volume], batchable: true))]
                ))
            }
            if let cache = snap.buildCache, cache > 0 {
                items.append(Item(
                    id: "\(id)|buildcache", categoryID: id, title: "Docker build cache", detail: "docker builder prune",
                    size: cache, risk: .safe, note: "Cached build layers. Builds take longer the first time afterwards.",
                    steps: [.run(ShellCommand(snap.docker, ["builder", "prune", "-af"]))]
                ))
            }
        }

        let vmNote = "A virtual machine or container disk. Everything inside it is deleted."
        let locations: [Loc] = [
            .whole("~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "Docker Desktop disk image", .caution,
                   "Holds ALL Docker images, containers and volumes. Quit Docker Desktop first; it creates a fresh, empty disk next time."),
            .whole("~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data", "OrbStack data", .caution,
                   "All OrbStack containers, images and Linux machines."),
            .children("~/.colima/_lima", "Colima VM", .caution, vmNote, skip: ["_config", "_networks"], dirsOnly: true),
            .children("~/.lima", "Lima VM", .caution, vmNote, skip: ["_config", "_networks", "_disks"], dirsOnly: true),
            .children("~/.local/share/containers/podman/machine", "Podman machine", .caution, vmNote, dirsOnly: true),
            .whole("~/.local/share/containers/storage", "Podman images & containers", .caution, vmNote),
            .whole("~/Library/Application Support/rancher-desktop/lima", "Rancher Desktop VM", .caution, vmNote),
            .children("~/.vagrant.d/boxes", "Vagrant box", .review, "A base image Vagrant copies when creating machines. It's downloaded again if a Vagrantfile needs it.", dirsOnly: true),
            .whole("~/.vagrant.d/tmp", "Vagrant temporary files", .safe, "Leftover downloads."),
            .children("~/VirtualBox VMs", "VirtualBox", .caution, vmNote, dirsOnly: true),
            .children("~/Parallels", nil, .caution, vmNote),
            .children("~/Documents/Parallels", nil, .caution, vmNote),
            .children("~/Virtual Machines.localized", nil, .caution, vmNote),
            .children("~/Documents/Virtual Machines.localized", nil, .caution, vmNote),
            .children("~/Library/Containers/com.utmapp.UTM/Data/Documents", nil, .caution, vmNote, extensions: ["utm"]),
            .children("~/.tart/vms", "Tart VM", .caution, vmNote, dirsOnly: true),
            .whole("~/.tart/cache", "Tart image cache", .safe, "Downloaded VM images, fetched again when needed."),
            .children("~/.minikube/machines", "minikube", .caution, vmNote, skip: ["server.pem", "server-key.pem"], dirsOnly: true),
            .whole("~/.minikube/cache", "minikube cache", .safe, "Downloaded Kubernetes images and binaries."),
            .whole("~/.kube/cache", "kubectl cache", .safe, "Cached API discovery data."),
        ]
        items += await Locations.scan(locations, category: id, ctx: ctx)
        return ScanResult(items.bySize(), notes: notes)
    }
}
