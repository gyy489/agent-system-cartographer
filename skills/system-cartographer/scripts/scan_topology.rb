#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "find"
require "json"
require "optparse"
require "pathname"
require "set"
require "time"
require "yaml"

class SystemCartographer
  TOP_LEVEL_ROLES = {
    "core" => "Deterministic resolve, search, workflow, and health-check interface",
    "catalog" => "Project, resource, policy, package, and deployment facts",
    "capabilities" => "Versioned capability packages containing Skills, Agents, tools, adapters, and workflows",
    "var" => "Rebuildable runtime state, cache, logs, and reports",
    "agents" => "Agent source, manifests, and launch metadata",
    "skills" => "Skill subsystem: source, active surface, registries, docs, contexts, logs, outputs, audits",
    "connectors" => "External-service connectors and integration notes",
    "dependencies" => "Shared dependency runtimes",
    "environments" => "Rebuildable Agent and project environments",
    "contexts" => "Project-level Agent runtime state and workspaces",
    "logs" => "Project-level Agent runtime and maintenance logs",
    "knowledge" => "Personal knowledge base, inbox files, notes, and reusable materials",
    "mcp" => "MCP server definitions, adapters, and local integration notes",
    "workflows" => "Cross-agent workflows and operating procedures",
    "scripts" => "Project launchers and maintenance commands",
    "registries" => "Machine-readable component declarations",
    "inventories" => "Project-level system snapshots and audits",
    "development" => "Human-maintained development notes, reports, and decisions",
    "docs" => "Project-level architecture and policy documentation"
  }.freeze

  PATH_FIELD_LABELS = {
    "source_path" => "源码路径 / Source path",
    "manifest" => "清单 / Manifest",
    "environment" => "运行环境 / Environment",
    "launcher" => "启动器 / Launcher",
    "workspace" => "工作区 / Workspace",
    "state" => "状态目录 / State",
    "skills_root" => "Skill 根目录 / Skill root"
  }.freeze

  PATH_FIELDS = %w[
    source_path manifest environment launcher workspace state skills_root
  ].freeze

  SKILL_CONTEXT_PATH = "skills/contexts/system-cartographer"
  SKILL_OUTPUT_PATH = "skills/outputs/system-cartographer/topology"
  SKILL_LOG_PATH = "skills/logs/system-cartographer/scan.log"
  SKILL_REGISTRY_PATH = "skills/registries/skills_registry.yaml"
  LEGACY_SKILL_REGISTRY_PATH = "registries/skills_registry.yaml"
  SOURCE_SKILL_DIRS = %w[
    capabilities
    skills/.system
    skills/inbox
    skills/official
    skills/personal
    skills/third-party
    skills/工具skills
    skills/论文写作skills
  ].freeze
  SKILL_INTERNAL_DIRS = %w[
    .active
    .runtime
    .git
    .trash
    artifacts
    audits
    contexts
    docs
    inventories
    logs
    node_modules
    outputs
    releases
    registries
    __pycache__
  ].freeze

  def initialize(options)
    @root = Pathname.new(options.fetch(:root)).expand_path.cleanpath
    @context_dir = managed_path(options[:context_dir] || SKILL_CONTEXT_PATH)
    @output_dir = managed_path(options[:output_dir] || SKILL_OUTPUT_PATH)
    @log_file = managed_path(options[:log_file] || SKILL_LOG_PATH)
    @strict = options.fetch(:strict, false)
    @errors = []
    @warnings = []
    @info = []
  end

  def run
    abort_with("Project root does not exist: #{@root}") unless @root.directory?

    registry_skills = load_registry_skills
    source_skills = scan_source_skills
    active_skills = scan_active_skills
    skills = merge_skills(source_skills, active_skills, registry_skills)
    agents = load_agents
    directories = scan_directories
    relationships = build_relationships(agents, skills)

    audit_skills(source_skills, active_skills, registry_skills)
    audit_agents(agents)

    topology = {
      "generated_at" => Time.now.utc.iso8601,
      "project_root" => @root.to_s,
      "summary" => {
        "agents" => agents.length,
        "source_skills" => source_skills.length,
        "active_skills" => active_skills.length,
        "registered_skills" => registry_skills.length,
        "errors" => @errors.length,
        "warnings" => @warnings.length,
        "info" => @info.length
      },
      "directories" => directories,
      "agents" => agents,
      "skills" => skills,
      "relationships" => relationships,
      "audit" => {
        "errors" => @errors,
        "warnings" => @warnings,
        "info" => @info
      }
    }

    write_outputs(topology)
    print_summary(topology.fetch("summary"))
    exit 2 if @strict && !@errors.empty?
  end

  private

  def managed_path(value)
    path = Pathname.new(value)
    path = @root.join(path) unless path.absolute?
    path = path.expand_path.cleanpath
    root_prefix = "#{@root}#{File::SEPARATOR}"
    abort_with("Managed path must stay inside project root: #{path}") unless path.to_s.start_with?(root_prefix)
    path
  end

  def abort_with(message)
    warn(message)
    exit 1
  end

  def load_yaml(path)
    return {} unless path.file?

    YAML.safe_load(path.read, [], [], false) || {}
  rescue Psych::Exception => e
    @errors << finding("invalid_yaml", relative(path), e.message.lines.first.to_s.strip)
    {}
  end

  def load_registry_skills
    registry_path = @root.join(SKILL_REGISTRY_PATH)
    registry_path = @root.join(LEGACY_SKILL_REGISTRY_PATH) unless registry_path.file?
    @skill_registry_data = load_yaml(registry_path)
    list = @skill_registry_data["skills"]
    list.is_a?(Array) ? list.select { |item| item.is_a?(Hash) } : []
  end

  def active_surface_path
    @skill_registry_data&.dig("management", "active_surface") || "skills/.active"
  end

  def v2_skill_lifecycle?
    @skill_registry_data.fetch("version", 1).to_i >= 2
  end

  def load_agents
    registry_path = @root.join("registries/agents_registry.yaml")
    data = load_yaml(registry_path)
    list = data["agents"]
    return [] unless list.is_a?(Array)

    list.select { |item| item.is_a?(Hash) }.map do |agent|
      normalized = agent.dup
      manifest_value = agent["manifest"]
      if manifest_value
        manifest_path = @root.join(manifest_value)
        manifest = load_yaml(manifest_path)
        normalized["manifest_data"] = manifest unless manifest.empty?
      end
      normalized
    end
  end

  def scan_source_skills
    found = []
    SOURCE_SKILL_DIRS.each do |relative_root|
      skills_root = @root.join(relative_root)
      next unless skills_root.directory?

      Find.find(skills_root.to_s) do |entry|
        path = Pathname.new(entry)
        if path.directory?
          if SKILL_INTERNAL_DIRS.include?(path.basename.to_s)
            Find.prune
          else
            next
          end
        end

        next unless path.basename.to_s == "SKILL.md"

        metadata = skill_frontmatter(path)
        name = metadata["name"] || path.dirname.basename.to_s
        found << {
          "name" => name,
          "description" => metadata["description"],
          "source_path" => relative(path.dirname),
          "skill_file" => relative(path)
        }
      end
    end
    found.uniq { |item| item.fetch("skill_file") }
         .sort_by { |item| [item.fetch("name"), item.fetch("source_path")] }
  end

  def scan_active_skills
    active_root = @root.join(active_surface_path)
    return [] unless active_root.directory?

    candidates = []
    active_root.children.sort.each do |path|
      if path.basename.to_s == ".system" && path.directory?
        candidates.concat(path.children.sort)
      else
        candidates << path
      end
    end

    candidates.each_with_object([]) do |path, found|
      if path.symlink? && !path.exist?
        @errors << finding("broken_active_link", relative(path), "Global Skill surface link target does not exist")
        next
      end

      skill_file = path.join("SKILL.md")
      next unless skill_file.file?

      metadata = skill_frontmatter(skill_file)
      found << {
        "name" => metadata["name"] || path.basename.to_s,
        "active_path" => relative(path),
        "source_path" => relative(Pathname.new(File.realpath(path))),
        "link_type" => path.symlink? ? "symlink" : "directory"
      }
    end.sort_by { |item| item.fetch("name") }
  end

  def skill_frontmatter(path)
    content = path.read(encoding: "UTF-8")
    match = content.match(/\A---\s*\n(.*?)\n---\s*\n/m)
    return {} unless match

    data = YAML.safe_load(match[1], [], [], false)
    data.is_a?(Hash) ? data : {}
  rescue StandardError => e
    @errors << finding("invalid_skill_frontmatter", relative(path), e.message)
    {}
  end

  def merge_skills(source_skills, active_skills, registry_skills)
    sources_by_name = source_skills.group_by { |item| item["name"] }
    active_by_name = active_skills.group_by { |item| item["name"] }
    registry_by_name = registry_skills.group_by { |item| item["name"] }
    names = (sources_by_name.keys + active_by_name.keys + registry_by_name.keys).compact.uniq.sort

    names.map do |name|
      source = sources_by_name.fetch(name, []).first
      active = active_by_name.fetch(name, []).first
      registry = registry_by_name.fetch(name, []).first
      {
        "name" => name,
        "category" => registry && registry["category"],
        "status" => registry && registry["status"],
        "source_path" => source&.fetch("source_path", nil) || active&.fetch("source_path", nil),
        "active_path" => active&.fetch("active_path", nil),
        "active" => !active.nil?,
        "description" => source&.fetch("description", nil),
        "registered_path" => registry && registry["path"]
      }.compact
    end
  end

  def scan_directories
    TOP_LEVEL_ROLES.map do |name, role|
      path = @root.join(name)
      {
        "path" => name,
        "role" => role,
        "exists" => path.directory?
      }
    end
  end

  def build_relationships(agents, skills)
    relationships = []
    active_surface = active_surface_path

    skills.select { |skill| skill["active"] }.each do |skill|
      relationships << edge(active_surface, "skill:#{skill['name']}", "available_to")
      if skill["source_path"]
        relationships << edge("skill:#{skill['name']}", skill["source_path"], "source_of")
      end
    end

    agents.each do |agent|
      agent_id = "agent:#{agent['id'] || agent['name']}"
      PATH_FIELDS.each do |field|
        value = agent[field]
        relationships << edge(agent_id, value, "configured_#{field}") if value.is_a?(String)
      end
    end

    cartographer = "skill:system-cartographer"
    relationships.concat([
      edge(cartographer, "registries", "reads_metadata"),
      edge(cartographer, "agents/manifests", "reads_metadata"),
      edge(cartographer, SKILL_REGISTRY_PATH, "reads_skill_metadata"),
      edge(cartographer, SKILL_CONTEXT_PATH, "writes_state"),
      edge(cartographer, "skills/logs/system-cartographer", "writes_logs"),
      edge(cartographer, SKILL_OUTPUT_PATH, "publishes")
    ])
    relationships.uniq
  end

  def edge(from, to, type)
    { "from" => from, "to" => to, "type" => type }
  end

  def audit_skills(source_skills, active_skills, registry_skills)
    duplicate_findings(source_skills, "duplicate_source_skill")
    duplicate_findings(active_skills, "duplicate_active_skill")
    duplicate_findings(registry_skills, "duplicate_registered_skill")

    active_names = active_skills.map { |item| item["name"] }.to_set
    registered_names = registry_skills.map { |item| item["name"] }.to_set

    (active_names - registered_names).sort.each do |name|
      @warnings << finding("active_skill_unregistered", name, "Globally visible Skill is missing from skills_registry.yaml")
    end

    registry_skills.each do |item|
      name = item["name"]
      path = item["path"]
      if path && !@root.join(path).exist?
        @errors << finding("registered_skill_path_missing", name, path)
      end
      if !v2_skill_lifecycle? && item["status"] == "active" && !active_names.include?(name)
        @warnings << finding("registered_active_skill_not_exposed", name, "No matching entry in #{active_surface_path}")
      end
    end

    source_skills.each do |item|
      next if active_names.include?(item["name"])

      code = v2_skill_lifecycle? ? "source_skill_not_globally_visible" : "source_skill_inactive"
      @info << finding(code, item["name"], item["source_path"])
    end
  end

  def audit_agents(agents)
    agents.each do |agent|
      id = agent["id"] || agent["name"] || "unknown"
      PATH_FIELDS.each do |field|
        value = agent[field]
        next unless value.is_a?(String)
        next if @root.join(value).exist?

        @errors << finding("agent_path_missing", id, "#{field}=#{value}")
      end
    end
  end

  def duplicate_findings(items, code)
    items.group_by { |item| item["name"] }.each do |name, matches|
      next if name.nil? || matches.length < 2

      @errors << finding(code, name, "#{matches.length} entries")
    end
  end

  def finding(code, subject, detail)
    { "code" => code, "subject" => subject, "detail" => detail }
  end

  def write_outputs(topology)
    generated_dir = @context_dir.join("generated")
    state_dir = @context_dir.join("state")
    [@context_dir.join("cache"), generated_dir, state_dir, @context_dir.join("workspace"),
     @output_dir, @log_file.dirname].each { |dir| FileUtils.mkdir_p(dir) }

    yaml = YAML.dump(topology)
    write_file(generated_dir.join("topology.yaml"), yaml)
    write_file(state_dir.join("last-scan.json"), JSON.pretty_generate(topology.fetch("summary")) + "\n")
    write_file(@output_dir.join("topology.yaml"), yaml)

    physical = physical_mermaid(topology)
    logical = logical_mermaid(topology)
    runtime = runtime_mermaid
    write_file(@output_dir.join("physical-topology.mmd"), physical)
    write_file(@output_dir.join("logical-topology.mmd"), logical)
    write_file(@output_dir.join("runtime-topology.mmd"), runtime)
    write_file(@output_dir.join("topology-audit.md"), audit_markdown(topology))
    write_file(@output_dir.join("system-map.md"), system_map_markdown(topology, physical, logical, runtime))

    File.open(@log_file, "a") do |file|
      summary = topology.fetch("summary")
      file.puts([
        topology.fetch("generated_at"),
        "root=#{@root}",
        "agents=#{summary['agents']}",
        "active_skills=#{summary['active_skills']}",
        "errors=#{summary['errors']}",
        "warnings=#{summary['warnings']}"
      ].join(" "))
    end
  end

  def write_file(path, content)
    File.write(path, content)
  end

  def physical_mermaid(topology)
    lines = ["flowchart LR", %(  root["#{mermaid_label(@root.basename.to_s)}"])]
    topology.fetch("directories").each do |directory|
      next unless directory["exists"]

      id = node_id("dir", directory["path"])
      lines << %(  #{id}["#{mermaid_label(directory['path'] + '/')}"])
      lines << "  root --> #{id}"
    end

    topology.fetch("agents").each do |agent|
      agent_name = agent["name"] || agent["id"]
      agent_id = node_id("agent", agent_name)
      lines << %(  #{agent_id}["智能体 / Agent: #{mermaid_label(agent_name)}"])
      lines << "  #{node_id('dir', 'agents')} --> #{agent_id}"
      PATH_FIELDS.each do |field|
        value = agent[field]
        next unless value.is_a?(String)

        path_id = node_id("path", "#{agent_name}:#{field}:#{value}")
        lines << %(  #{path_id}["#{mermaid_label(PATH_FIELD_LABELS.fetch(field, field))}<br/>#{mermaid_label(value)}"])
        lines << "  #{agent_id} --> #{path_id}"
      end
    end

    lines << %(  active["#{mermaid_label(active_surface_path)}"])
    lines << "  #{node_id('dir', 'skills')} --> active"
    topology.fetch("skills").select { |skill| skill["active"] }.each do |skill|
      id = node_id("physical_skill", skill["name"])
      source = skill["source_path"] || "来源未知 / Source unknown"
      label = "技能 / Skill: #{skill['name']}<br/>#{source}"
      lines << %(  #{id}["#{mermaid_label(label)}"])
      lines << "  active --> #{id}"
    end
    lines << %(  cartctx["#{SKILL_CONTEXT_PATH}"])
    lines << "  #{node_id('dir', 'skills')} --> cartctx"
    lines << %(  topoout["#{SKILL_OUTPUT_PATH}"])
    lines << "  #{node_id('dir', 'skills')} --> topoout"
    lines.join("\n") + "\n"
  end

  def logical_mermaid(topology)
    lines = [
      "flowchart LR",
      %(  user["用户 / User"]),
      %(  codex["Codex"]),
      %(  active["全局可见 Skill 接口<br/>Globally visible Skill surface"]),
      "  user --> codex",
      "  codex --> active"
    ]

    topology.fetch("agents").each do |agent|
      name = agent["name"] || agent["id"]
      id = node_id("agent", name)
      lines << %(  #{id}["智能体 / Agent: #{mermaid_label(name)}"])
      lines << "  user --> #{id}"
      lines << "  #{id} -. 可用 Skills / available Skills .-> active" if agent["skills_root"]
    end

    topology.fetch("skills").select { |skill| skill["active"] }.each do |skill|
      id = node_id("skill", skill["name"])
      lines << %(  #{id}["#{mermaid_label(skill['name'])}"])
      lines << "  active --> #{id}"
    end

    cartographer = node_id("skill", "system-cartographer")
    lines.concat([
      %(  registries["注册表 / Registries<br/>registries/*.yaml"]),
      %(  skill_registry["Skill 注册表 / Skill registry<br/>#{SKILL_REGISTRY_PATH}"]),
      %(  manifests["Agent 清单 / Agent manifests<br/>agents/manifests/*.yaml"]),
      %(  state["制图器状态 / Cartographer state<br/>#{SKILL_CONTEXT_PATH}"]),
      %(  maps["拓扑清单 / Topology inventories<br/>#{SKILL_OUTPUT_PATH}"]),
      "  #{cartographer} -->|读取 / reads| registries",
      "  #{cartographer} -->|读取 / reads| skill_registry",
      "  #{cartographer} -->|读取 / reads| manifests",
      "  #{cartographer} -->|写入状态 / writes state| state",
      "  #{cartographer} -->|发布 / publishes| maps"
    ])
    lines.join("\n") + "\n"
  end

  def runtime_mermaid
    <<~MERMAID
      sequenceDiagram
        actor User as 用户 / User
        participant Codex
        participant Cartographer as 系统制图器 / system-cartographer
        participant Metadata as 注册表与清单 / Registries and manifests
        participant State as 状态目录 / skills/contexts
        participant Inventory as 拓扑清单 / skills/outputs/system-cartographer/topology
        User->>Codex: 请求拓扑扫描 / Request topology scan
        Codex->>Cartographer: 运行确定性扫描器 / Run deterministic scanner
        Cartographer->>Metadata: 读取声明关系 / Read declared relationships
        Cartographer->>Cartographer: 检查路径、链接和 Skill 元数据 / Inspect paths, links, and Skill frontmatter
        Cartographer->>State: 保存工作快照 / Save working snapshot
        Cartographer->>Inventory: 发布图表与审计 / Publish maps and audit
        Cartographer-->>Codex: 返回计数与发现 / Return counts and findings
        Codex-->>User: 解释拓扑与不一致项 / Explain topology and inconsistencies
    MERMAID
  end

  def audit_markdown(topology)
    audit = topology.fetch("audit")
    lines = [
      "# 拓扑审计 / Topology Audit",
      "",
      "生成时间 / Generated: `#{topology.fetch('generated_at')}`",
      "",
      "项目根目录 / Project root: `#{topology.fetch('project_root')}`",
      ""
    ]
    {
      "错误 / Errors" => audit.fetch("errors"),
      "警告 / Warnings" => audit.fetch("warnings"),
      "信息 / Information" => audit.fetch("info")
    }.each do |heading, findings|
      lines << "## #{heading} (#{findings.length})"
      lines << ""
      if findings.empty?
        lines << "无 / None."
      else
        findings.each do |item|
          lines << "- `#{item['code']}`: `#{item['subject']}` - #{item['detail']}"
        end
      end
      lines << ""
    end
    lines.join("\n")
  end

  def system_map_markdown(topology, physical, logical, runtime)
    summary = topology.fetch("summary")
    <<~MARKDOWN
      # #{@root.basename} 系统拓扑 / System Map

      生成时间 / Generated: `#{topology.fetch('generated_at')}`

      源码根目录 / Source root: `#{topology.fetch('project_root')}`

      ## 快照 / Snapshot

      | 资产 / Asset | 数量 / Count |
      |---|---:|
      | 已注册 Agent / Registered Agents | #{summary['agents']} |
      | 源码 Skills / Source Skills | #{summary['source_skills']} |
      | 全局可见 Skills / Globally visible Skills | #{summary['active_skills']} |
      | 已注册 Skills / Registered Skills | #{summary['registered_skills']} |
      | 错误 / Errors | #{summary['errors']} |
      | 警告 / Warnings | #{summary['warnings']} |

      机器可读数据 / Machine-readable data: [topology.yaml](topology.yaml)

      审计 / Audit: [topology-audit.md](topology-audit.md)

      ## 物理拓扑 / Physical Topology

      ```mermaid
      #{physical.rstrip}
      ```

      ## 逻辑拓扑 / Logical Topology

      ```mermaid
      #{logical.rstrip}
      ```

      ## 运行时拓扑 / Runtime Topology

      ```mermaid
      #{runtime.rstrip}
      ```

      ## 证据边界 / Evidence Boundary

      本图根据文件系统元数据、Skill frontmatter、注册表和 Agent 清单生成。
      全局可见 Skill 连线表示“可发现”，不表示项目 Profile 已挂载或每次 Agent 运行都会实际调用。

      This map is generated from filesystem metadata, Skill frontmatter,
      registries, and Agent manifests. A globally visible Skill edge means
      discoverability, not a project Profile mount or confirmed invocation.
    MARKDOWN
  end

  def mermaid_label(value)
    value.to_s.gsub('"', "'").gsub(/\s+/, " ")
  end

  def node_id(prefix, value)
    "#{prefix}_#{Digest::SHA1.hexdigest(value.to_s)[0, 10]}"
  end

  def relative(path)
    expanded = Pathname.new(path).expand_path.cleanpath
    expanded.relative_path_from(@root).to_s
  rescue ArgumentError
    expanded.to_s
  end

  def print_summary(summary)
    puts "拓扑已生成 / Topology generated"
    puts "  根目录 / root: #{@root}"
    puts "  输出 / output: #{@output_dir}"
    puts "  Agent 数量 / agents: #{summary['agents']}"
    puts "  全局可见 Skills / globally visible skills: #{summary['active_skills']}"
    puts "  已注册 Skills / registered skills: #{summary['registered_skills']}"
    puts "  错误 / errors: #{summary['errors']}"
    puts "  警告 / warnings: #{summary['warnings']}"
  end
end

options = {
  root: Dir.pwd,
  strict: false
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: scan_topology.rb [options]"
  opts.on("--root PATH", "Project root to scan") { |value| options[:root] = value }
  opts.on("--context-dir PATH", "Managed state directory inside the project") { |value| options[:context_dir] = value }
  opts.on("--output-dir PATH", "Published output directory inside the project") { |value| options[:output_dir] = value }
  opts.on("--log-file PATH", "Log file inside the project") { |value| options[:log_file] = value }
  opts.on("--strict", "Exit 2 when audit errors are found") { options[:strict] = true }
  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end

parser.parse!

SystemCartographer.new(options).run
