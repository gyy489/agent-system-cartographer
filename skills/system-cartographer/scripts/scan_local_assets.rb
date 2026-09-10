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

class LocalAssetCartographer
  HOST_KIND_LABELS = {
    "coding_agent" => "编码智能体 / Coding agent",
    "multi_agent_application" => "多智能体应用 / Multi-agent application",
    "ai_coding_assistant" => "AI 编码助手 / AI coding assistant"
  }.freeze

  SURFACE_KIND_LABELS = {
    "cli" => "命令行 / CLI",
    "desktop_app" => "桌面应用 / Desktop app",
    "vscode_extension" => "VS Code 扩展 / VS Code extension",
    "project_launcher" => "项目启动器 / Project launcher",
    "ai_client" => "AI 客户端 / AI client"
  }.freeze

  STATUS_LABELS = {
    "installed_active" => "已安装，活跃 / Installed, active",
    "installed_unconfigured" => "已安装，未配置 / Installed, unconfigured",
    "installed" => "已安装 / Installed",
    "installed_vscode" => "已安装于 VS Code / Installed in VS Code"
  }.freeze

  LIFECYCLE_LABELS = {
    "canonical_source" => "规范源码 / Canonical source",
    "compatibility_catalog" => "审批兼容目录 / Approved compatibility catalog",
    "release_store" => "不可变发布存储 / Immutable Release store",
    "active" => "活跃接口 / Active surface",
    "active_alias" => "活跃别名 / Active alias",
    "active_user" => "用户级活跃源 / Active user source",
    "runtime_builtin" => "运行时内置 / Runtime built-in",
    "backup" => "备份 / Backup",
    "bundled_agent_internal" => "Agent 内置 / Bundled inside Agent",
    "standalone_project_source" => "独立项目源码 / Standalone project source",
    "dependency_source" => "依赖源码 / Dependency source",
    "vendor_catalog" => "供应商目录 / Vendor catalog",
    "temporary_catalog" => "临时目录 / Temporary catalog",
    "cache" => "缓存 / Cache",
    "generated_surface" => "生成运行面 / Generated runtime surface"
  }.freeze

  LOCATION_LABELS = {
    "project-source" => "两头乌 Skill 源码库 / Liang-Tou-Wu Skill source library",
    "project-active" => "项目活跃 Skill 接口 / Project active Skill surface",
    "codex-active-alias" => "Codex 活跃 Skill 别名 / Codex active Skill alias",
    "codex-runtime-builtins" => "Codex 运行时内置 Skills / Codex runtime built-ins",
    "claude-active-alias" => "Claude Code 活跃 Skill 别名 / Claude Code active Skill alias",
    "claude-controlled-surface" => "Claude Code 受控 Skill 运行面 / Claude Code controlled Skill surface",
    "openclaw-prepared-surface" => "OpenClaw 预备 Skill 运行面 / OpenClaw prepared Skill surface",
    "open-agent-user" => "用户 Agent Skills / User Agent Skills",
    "skills-inbox" => "两头乌 Skill 候选区 / Liang-Tou-Wu Skill inbox",
    "official-openai-skills" => "OpenAI 官方 Skill 源码层 / OpenAI official Skill source layer",
    "official-anthropic-skills" => "Anthropic 官方 Skill 源码层 / Anthropic official Skill source layer",
    "personal-skills" => "个人 Skill 源码层 / Personal Skill source layer",
    "third-party-skills" => "第三方 Skill 源码层 / Third-party Skill source layer",
    "codex-local-backup" => "Codex 本地 Skill 备份 / Codex local Skill backup",
    "evoscientist-bundled-skills" => "EvoScientist 内置 Skills / EvoScientist bundled Skills",
    "ielts-project-skill" => "IELTS 项目 Skill 源码 / IELTS project Skill source",
    "blogwatcher-module-skill" => "Blogwatcher Go 模块 Skill / Blogwatcher Go module Skill",
    "codex-vendor-catalog" => "Codex 供应商 Skill 目录 / Codex vendor Skill catalog",
    "codex-plugin-temp-catalog" => "Codex 临时插件目录 / Codex temporary plugin catalog",
    "codex-plugin-cache" => "Codex 插件缓存 / Codex plugin cache"
  }.freeze

  CATEGORY_LABELS = {
    "coding/research" => "编码/研究 / Coding/research",
    "document" => "文档 / Document",
    "research/experiment" => "研究/实验 / Research/experiment",
    "research/ideation" => "研究/构思 / Research/ideation",
    "research/literature" => "研究/文献 / Research/literature",
    "research/math" => "研究/数学 / Research/math",
    "research/memory" => "研究/记忆 / Research/memory",
    "research/slides" => "研究/幻灯片 / Research/slides",
    "research/social-science" => "研究/社会科学 / Research/social science",
    "research/survey" => "研究/综述 / Research/survey",
    "research/writing" => "研究/写作 / Research/writing",
    "slides/media" => "幻灯片/媒体 / Slides/media",
    "system/architecture" => "系统/架构 / System/architecture",
    "system/docs" => "系统/文档 / System/docs",
    "system/media" => "系统/媒体 / System/media",
    "system/plugin" => "系统/插件 / System/plugin",
    "system/review" => "系统/审查 / System/review",
    "system/skills" => "系统/Skills / System/Skills",
    "system/web-research" => "系统/网络研究 / System/web research",
    "voice" => "语音 / Voice",
    "unclassified" => "未分类 / Unclassified"
  }.freeze

  SKILL_CONTEXT_PATH = "skills/contexts/system-cartographer"
  SKILL_OUTPUT_PATH = "skills/outputs/system-cartographer/topology"
  SKILL_LOG_PATH = "skills/logs/system-cartographer/scan.log"
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
    @strict = options.fetch(:strict, false)
    @registry_path = @root.join("registries/cartography_registry.yaml")
    @base_topology_path = @root.join("#{SKILL_OUTPUT_PATH}/topology.yaml")
    @output_dir = @root.join(SKILL_OUTPUT_PATH)
    @context_dir = @root.join(SKILL_CONTEXT_PATH)
    @log_file = @root.join(SKILL_LOG_PATH)
    @errors = []
    @warnings = []
    @info = []
  end

  def run
    abort_with("Missing cartography registry: #{@registry_path}") unless @registry_path.file?
    abort_with("Run scan_topology.rb first: #{@base_topology_path}") unless @base_topology_path.file?

    registry = load_yaml(@registry_path)
    base = load_yaml(@base_topology_path)
    hosts = inspect_hosts(registry.fetch("agent_hosts", []))
    clients = inspect_clients(registry.fetch("client_surfaces", []))
    locations = inspect_skill_locations(registry.fetch("skill_locations", []))
    unique_physical_skill_files = locations.flat_map { |item| item.delete("_realpaths") || [] }.uniq.length
    inspect_expected_links(registry.fetch("expected_links", []))
    audit_discovery_duplicates(locations)

    topology = {
      "generated_at" => Time.now.utc.iso8601,
      "project_root" => @root.to_s,
      "summary" => {
        "agent_hosts" => hosts.length,
        "client_surfaces" => clients.length,
        "unique_active_skills" => base.dig("summary", "active_skills") || 0,
        "skill_locations" => locations.length,
        "skill_files_across_locations" => locations.sum { |item| item["skill_count"] },
        "unique_physical_skill_files" => unique_physical_skill_files,
        "errors" => @errors.length,
        "warnings" => @warnings.length,
        "info" => @info.length
      },
      "agent_hosts" => hosts,
      "client_surfaces" => clients,
      "skill_locations" => locations,
      "active_skills" => base.fetch("skills", []).select { |skill| skill["active"] },
      "managed_agents" => base.fetch("agents", []),
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

  def abort_with(message)
    warn(message)
    exit 1
  end

  def load_yaml(path)
    YAML.safe_load(path.read, [], [], false) || {}
  rescue Psych::Exception => e
    abort_with("Invalid YAML #{path}: #{e.message.lines.first.to_s.strip}")
  end

  def expand_path(value)
    Pathname.new(value.to_s.gsub("${PROJECT_ROOT}", @root.to_s)).expand_path.cleanpath
  end

  def inspect_hosts(entries)
    entries.map do |entry|
      host = entry.dup
      host["surfaces"] = entry.fetch("surfaces", []).map do |surface|
        inspect_declared_path(surface, "agent_surface_missing", entry["id"])
      end
      host["state_roots"] = entry.fetch("state_roots", []).map do |value|
        inspect_path_value(value, "agent_state_root_missing", entry["id"])
      end
      host
    end
  end

  def inspect_clients(entries)
    entries.map do |entry|
      inspect_declared_path(entry, "client_surface_missing", entry["id"])
    end
  end

  def inspect_declared_path(entry, error_code, owner)
    inspected = entry.dup
    path = expand_path(entry.fetch("path"))
    inspected["exists"] = path.exist?
    inspected["resolved_path"] = resolved_path(path)
    unless path.exist?
      @errors << finding(error_code, owner, path.to_s)
    end
    inspected
  end

  def inspect_path_value(value, error_code, owner)
    path = expand_path(value)
    exists = path.exist?
    @errors << finding(error_code, owner, path.to_s) unless exists
    {
      "path" => path.to_s,
      "exists" => exists,
      "resolved_path" => resolved_path(path)
    }.compact
  end

  def inspect_skill_locations(entries)
    entries.map do |entry|
      path = expand_path(entry.fetch("path"))
      exists = path.exist?
      unless exists
        @errors << finding("skill_location_missing", entry["id"], path.to_s)
        next entry.merge("exists" => false, "skill_count" => 0, "skill_names" => [])
      end

      files = skill_files(path, entry.fetch("scan_mode", "recursive"))
      names = if entry.fetch("detail", "aggregate") == "names"
                files.map { |file| skill_name(file) }.compact.uniq.sort
              else
                []
              end
      entry.merge(
        "exists" => true,
        "resolved_path" => resolved_path(path),
        "skill_count" => files.length,
        "skill_names" => names,
        "_realpaths" => files.map { |file| resolved_path(file) }.compact
      )
    end
  end

  def skill_files(root, mode)
    root = Pathname.new(File.realpath(root))
    return active_skill_files(root) if mode == "active_surface"

    files = []
    Find.find(root.to_s) do |entry|
      path = Pathname.new(entry)
      if path.directory?
        basename = path.basename.to_s
        if (path != root && SKILL_INTERNAL_DIRS.include?(basename)) ||
           (mode == "canonical_source" && path == root.join(".active"))
          Find.prune
        else
          next
        end
      end
      files << path if path.basename.to_s == "SKILL.md" && path.file?
    end
    files.sort_by(&:to_s)
  end

  def active_skill_files(root)
    candidates = []
    root.children.sort.each do |path|
      if path.basename.to_s == ".system" && path.directory?
        candidates.concat(path.children.sort)
      else
        candidates << path
      end
    end
    candidates.each_with_object([]) do |path, files|
      skill_file = path.join("SKILL.md")
      files << skill_file if skill_file.file?
    end
  end

  def skill_name(path)
    content = path.read(encoding: "UTF-8")
    match = content.match(/\A---\s*\n(.*?)\n---\s*\n/m)
    return path.dirname.basename.to_s unless match

    data = YAML.safe_load(match[1], [], [], false)
    data.is_a?(Hash) ? (data["name"] || path.dirname.basename.to_s) : path.dirname.basename.to_s
  rescue StandardError => e
    @warnings << finding("skill_name_unreadable", path.to_s, e.message)
    path.dirname.basename.to_s
  end

  def inspect_expected_links(entries)
    entries.each do |entry|
      path = expand_path(entry.fetch("path"))
      target = expand_path(entry.fetch("target"))
      required = entry.fetch("required", false)
      unless path.symlink?
        collection = required ? @errors : @warnings
        collection << finding("expected_link_missing", entry["id"], path.to_s)
        next
      end

      actual = Pathname.new(File.realpath(path))
      next if actual == Pathname.new(File.realpath(target))

      collection = required ? @errors : @warnings
      collection << finding("expected_link_target_mismatch", entry["id"], "#{actual} != #{target}")
    rescue Errno::ENOENT
      collection = required ? @errors : @warnings
      collection << finding("expected_link_broken", entry["id"], path.to_s)
    end
  end

  def audit_discovery_duplicates(locations)
    discovery = locations.select { |item| item["discovery"] && item["exists"] }
    locations_by_id = locations.each_with_object({}) { |item, index| index[item["id"]] = item }
    canonical_groups = discovery.group_by { |item| discovery_identity(item, locations_by_id) }
    names_by_identity = {}
    canonical_groups.each do |identity, entries|
      names_by_identity[identity] = entries.flat_map { |entry| entry["skill_names"] }.to_set
    end

    name_to_identities = Hash.new { |hash, key| hash[key] = [] }
    names_by_identity.each do |identity, names|
      names.each { |name| name_to_identities[name] << identity }
    end
    name_to_identities.each do |name, identities|
      next unless identities.uniq.length > 1

      @warnings << finding(
        "duplicate_skill_discovery",
        name,
        "Discovered from independent surfaces: #{identities.uniq.sort.join(', ')}"
      )
    end

    locations.each do |item|
      next if item["lifecycle"].to_s.match?(/\A(active|active_alias|active_user|runtime_builtin|canonical_source)\z/)

      @info << finding(
        "inactive_skill_store",
        item["id"],
        "#{item['lifecycle']}: #{item['skill_count']} SKILL.md files"
      )
    end
  end

  def discovery_identity(item, locations_by_id)
    return "group:#{item['duplicate_group']}" if item["duplicate_group"]

    current = item
    seen = Set.new
    loop do
      id = current["id"]
      return id if seen.include?(id)

      seen << id
      parent_id = current["alias_of"] || current["derived_from"]
      return id unless parent_id

      parent = locations_by_id[parent_id]
      return parent_id unless parent

      current = parent
    end
  end

  def write_outputs(topology)
    FileUtils.mkdir_p(@output_dir)
    FileUtils.mkdir_p(@context_dir.join("generated"))
    FileUtils.mkdir_p(@context_dir.join("state"))
    FileUtils.mkdir_p(@log_file.dirname)

    yaml = YAML.dump(topology)
    write_file(@output_dir.join("local-topology.yaml"), yaml)
    write_file(@context_dir.join("generated/local-topology.yaml"), yaml)

    overview = overview_mermaid(topology)
    agents = agent_mermaid(topology)
    discovery = skill_discovery_mermaid(topology)
    storage = skill_storage_mermaid(topology)
    write_file(@output_dir.join("complete-topology.mmd"), overview)
    write_file(@output_dir.join("local-agent-topology.mmd"), agents)
    write_file(@output_dir.join("skill-discovery-topology.mmd"), discovery)
    write_file(@output_dir.join("skill-storage-topology.mmd"), storage)
    write_file(@output_dir.join("local-topology-audit.md"), audit_markdown(topology))
    write_file(
      @output_dir.join("detailed-system-map.md"),
      detailed_map_markdown(topology, overview, agents, discovery, storage)
    )
    write_file(
      @context_dir.join("state/last-local-scan.json"),
      JSON.pretty_generate(topology.fetch("summary")) + "\n"
    )

    File.open(@log_file, "a") do |file|
      summary = topology.fetch("summary")
      file.puts([
        topology.fetch("generated_at"),
        "scope=local-assets",
        "agent_hosts=#{summary['agent_hosts']}",
        "unique_active_skills=#{summary['unique_active_skills']}",
        "skill_files=#{summary['skill_files_across_locations']}",
        "errors=#{summary['errors']}",
        "warnings=#{summary['warnings']}"
      ].join(" "))
    end
  end

  def overview_mermaid(topology)
    lines = [
      "flowchart LR",
      %(  user["用户 / User"]),
      %(  vscode["VS Code"]),
      %(  terminal["终端 / Terminal"]),
      %(  desktop["桌面应用 / Desktop apps"]),
      "  user --> vscode",
      "  user --> terminal",
      "  user --> desktop"
    ]
    topology.fetch("agent_hosts").each do |host|
      host_id = node_id("host", host["id"])
      lines << %(  #{host_id}["#{label(host['name'])}<br/>#{label(host['version'])}"])
      host.fetch("surfaces", []).each do |surface|
        parent = case surface["kind"]
                 when "vscode_extension" then "vscode"
                 when "desktop_app" then "desktop"
                 else "terminal"
                 end
        lines << "  #{parent} --> #{host_id}"
      end
      host.fetch("skill_surface_ids", []).each do |surface_id|
        skill_id = node_id("skill_surface", surface_id)
        lines << %(  #{skill_id}["#{label(surface_id)}"])
        lines << "  #{host_id} -->|发现 / discovers| #{skill_id}"
      end
    end
    topology.fetch("client_surfaces").each do |client|
      client_id = node_id("client", client["id"])
      lines << %(  #{client_id}["#{label(client['name'])}<br/>AI 客户端 / AI client #{label(client['version'])}"])
      lines << "  desktop --> #{client_id}"
    end
    lines << %(  inventory["拓扑清单 / Topology inventory<br/>#{SKILL_OUTPUT_PATH}"])
    lines << "  #{node_id('host', 'codex')} --> inventory"
    lines.join("\n") + "\n"
  end

  def agent_mermaid(topology)
    lines = ["flowchart TB", %(  user["用户 / User"])]
    topology.fetch("agent_hosts").each do |host|
      host_id = node_id("host", host["id"])
      kind = translated(HOST_KIND_LABELS, host["kind"])
      lines << %(  #{host_id}["#{label(host['name'])}<br/>#{diagram_bilingual(kind)}<br/>#{label(host['version'])}"])
      lines << "  user --> #{host_id}"
      host.fetch("surfaces", []).each do |surface|
        surface_id = node_id("surface", surface["id"])
        kind = translated(SURFACE_KIND_LABELS, surface["kind"])
        lines << %(  #{surface_id}["#{diagram_bilingual(kind)}<br/>#{label(surface['path'])}"])
        lines << "  #{surface_id} --> #{host_id}"
      end
      host.fetch("state_roots", []).each do |state|
        state_id = node_id("state", state["path"])
        lines << %(  #{state_id}["状态 / State<br/>#{label(state['path'])}"])
        lines << "  #{host_id} --> #{state_id}"
      end
    end
    topology.fetch("client_surfaces").each do |client|
      id = node_id("client", client["id"])
      lines << %(  #{id}["#{label(client['name'])}<br/>客户端 / Client #{label(client['version'])}"])
      lines << "  user --> #{id}"
    end
    lines.join("\n") + "\n"
  end

  def skill_discovery_mermaid(topology)
    lines = [
      "flowchart LR",
      %(  codex["Codex"]),
      %(  claude["Claude Code"]),
      %(  evo["EvoScientist"])
    ]
    locations = topology.fetch("skill_locations").to_h { |item| [item["id"], item] }
    %w[
      project-source project-active codex-active-alias claude-active-alias
      open-agent-user skills-inbox official-openai-skills
      official-anthropic-skills personal-skills third-party-skills
      evoscientist-bundled-skills
    ].each do |id|
      item = locations[id]
      next unless item

      name = translated(LOCATION_LABELS, id, item["name"])
      lines << %(  #{node_id('location', id)}["#{diagram_bilingual(name)}<br/>#{item['skill_count']} 个 Skill 文件 / Skill files<br/>#{label(item['path'])}"])
    end
    lines.concat([
      "  #{node_id('location', 'project-source')} -->|发布链接和托管副本 / publishes links and managed copies| #{node_id('location', 'project-active')}",
      "  #{node_id('location', 'project-active')} -->|指向同一目录 / same target| #{node_id('location', 'codex-active-alias')}",
      "  #{node_id('location', 'project-active')} -->|指向同一目录 / same target| #{node_id('location', 'claude-active-alias')}",
      "  #{node_id('location', 'codex-active-alias')} --> codex",
      "  #{node_id('location', 'claude-active-alias')} --> claude",
      "  #{node_id('location', 'open-agent-user')} --> codex",
      "  #{node_id('location', 'official-openai-skills')} -->|审计并审批后激活 / activate after review and approval| #{node_id('location', 'project-active')}",
      "  #{node_id('location', 'official-anthropic-skills')} -->|审计并审批后激活 / activate after review and approval| #{node_id('location', 'project-active')}",
      "  #{node_id('location', 'personal-skills')} -->|审计并审批后激活 / activate after review and approval| #{node_id('location', 'project-active')}",
      "  #{node_id('location', 'third-party-skills')} -->|审计并审批后激活 / activate after review and approval| #{node_id('location', 'project-active')}",
      "  #{node_id('location', 'skills-inbox')} -->|审计并审批后迁移或激活 / review and approve before migration or activation| #{node_id('location', 'project-active')}",
      "  #{node_id('location', 'project-active')} --> evo",
      "  #{node_id('location', 'evoscientist-bundled-skills')} --> evo"
    ])

    topology.fetch("active_skills").group_by { |skill| skill["category"] || "unclassified" }.sort.each do |category, skills|
      category_id = node_id("category", category)
      category_label = translated(CATEGORY_LABELS, category)
      lines << %(  #{category_id}["#{diagram_bilingual(category_label)}"])
      lines << "  #{node_id('location', 'project-active')} --> #{category_id}"
      skills.sort_by { |skill| skill["name"] }.each do |skill|
        skill_id = node_id("skill", skill["name"])
        lines << %(  #{skill_id}["#{label(skill['name'])}<br/>#{label(skill['source_path'])}"])
        lines << "  #{category_id} --> #{skill_id}"
      end
    end
    lines.join("\n") + "\n"
  end

  def skill_storage_mermaid(topology)
    lines = ["flowchart TB", %(  all["本机 Skill 存储位置<br/>Local Skill storage locations"])]
    topology.fetch("skill_locations").each do |item|
      id = node_id("store", item["id"])
      name = translated(LOCATION_LABELS, item["id"], item["name"])
      lifecycle = translated(LIFECYCLE_LABELS, item["lifecycle"])
      lines << %(  #{id}["#{diagram_bilingual(name)}<br/>#{diagram_bilingual(lifecycle)}<br/>#{item['skill_count']} 个 SKILL.md / SKILL.md files<br/>#{label(item['path'])}"])
      lines << "  all --> #{id}"
      if item["alias_of"]
        lines << "  #{id} -. 别名指向 / alias of .-> #{node_id('store', item['alias_of'])}"
      end
    end
    lines.concat([
      "  classDef active fill:#dff4e4,stroke:#287a3f,color:#14261a",
      "  classDef source fill:#e7f0ff,stroke:#3569a8,color:#142033",
      "  classDef inactive fill:#f3f3f3,stroke:#777,color:#222",
      "  class #{node_id('store', 'project-active')},#{node_id('store', 'codex-active-alias')},#{node_id('store', 'claude-active-alias')},#{node_id('store', 'open-agent-user')} active",
      "  class #{node_id('store', 'project-source')},#{node_id('store', 'official-openai-skills')},#{node_id('store', 'official-anthropic-skills')},#{node_id('store', 'personal-skills')},#{node_id('store', 'third-party-skills')} source",
      "  class #{node_id('store', 'skills-inbox')},#{node_id('store', 'codex-local-backup')},#{node_id('store', 'evoscientist-bundled-skills')},#{node_id('store', 'ielts-project-skill')},#{node_id('store', 'blogwatcher-module-skill')},#{node_id('store', 'codex-vendor-catalog')},#{node_id('store', 'codex-plugin-temp-catalog')},#{node_id('store', 'codex-plugin-cache')} inactive"
    ])
    lines.join("\n") + "\n"
  end

  def detailed_map_markdown(topology, overview, agents, discovery, storage)
    summary = topology.fetch("summary")
    host_rows = topology.fetch("agent_hosts").map do |host|
      surfaces = host.fetch("surfaces", []).map do |surface|
        translated(SURFACE_KIND_LABELS, surface["kind"])
      end.join(", ")
      kind = translated(HOST_KIND_LABELS, host["kind"])
      status = translated(STATUS_LABELS, host["status"])
      "| `#{host['name']}` | #{kind} | `#{host['version']}` | #{status} | #{surfaces} |"
    end.join("\n")
    location_rows = topology.fetch("skill_locations").map do |item|
      name = translated(LOCATION_LABELS, item["id"], item["name"])
      lifecycle = translated(LIFECYCLE_LABELS, item["lifecycle"])
      "| #{name} | #{lifecycle} | #{item['skill_count']} | `#{item['path']}` |"
    end.join("\n")
    skill_rows = topology.fetch("active_skills").sort_by { |skill| skill["name"] }.map do |skill|
      category = skill["category"] || "unclassified"
      category_label = translated(CATEGORY_LABELS, category)
      "| `#{skill['name']}` | #{category_label} (`#{category}`) | `#{skill['source_path']}` |"
    end.join("\n")

    <<~MARKDOWN
      # #{@root.basename} Agent 与 Skill 详细拓扑 / Detailed Agent And Skill Topology

      生成时间 / Generated: `#{topology.fetch('generated_at')}`

      ## 范围 / Scope

      - CLI、桌面端和 VS Code 中发现的 Agent 主机与 AI 编码助手 / Agent hosts and AI coding assistants found in CLI, desktop, and VS Code surfaces.
      - Codex 与 EvoScientist 的活跃 Skill 发现接口 / Active Codex and EvoScientist Skill discovery surfaces.
      - 规范源码、用户级、备份、供应商、临时目录和缓存中的 Skill 存储 / Canonical, user, backup, vendor, temporary catalog, and cache Skill storage.
      - 仅使用声明的元数据与文件路径，不读取凭据或对话内容 / Only declared metadata and filesystem paths; no credential or conversation content.

      ## 摘要 / Summary

      | 资产 / Asset | 数量 / Count |
      |---|---:|
      | Agent 主机与编码助手 / Agent hosts and coding assistants | #{summary['agent_hosts']} |
      | AI 客户端界面 / AI client surfaces | #{summary['client_surfaces']} |
      | 唯一活跃 Skills / Unique active Skills | #{summary['unique_active_skills']} |
      | Skill 存储与发现位置 / Skill storage/discovery locations | #{summary['skill_locations']} |
      | 各位置中的 SKILL.md 路径数 / SKILL.md path occurrences across locations | #{summary['skill_files_across_locations']} |
      | 唯一物理 SKILL.md 文件 / Unique physical SKILL.md files | #{summary['unique_physical_skill_files']} |
      | 错误 / Errors | #{summary['errors']} |
      | 警告 / Warnings | #{summary['warnings']} |

      详细数据 / Detailed data: [local-topology.yaml](local-topology.yaml)

      审计 / Audit: [local-topology-audit.md](local-topology-audit.md)

      ## 完整总览 / Complete Overview

      ```mermaid
      #{overview.rstrip}
      ```

      ## Agent 主机与界面 / Agent Hosts And Surfaces

      ```mermaid
      #{agents.rstrip}
      ```

      | 主机 / Host | 类型 / Kind | 版本 / Version | 状态 / Status | 界面 / Surfaces |
      |---|---|---|---|---|
      #{host_rows}

      ## Skill 发现与来源 / Skill Discovery And Sources

      ```mermaid
      #{discovery.rstrip}
      ```

      | 活跃 Skill / Active Skill | 分类 / Category | 来源 / Source |
      |---|---|---|
      #{skill_rows}

      ## Skill 存储生命周期 / Skill Storage Lifecycle

      ```mermaid
      #{storage.rstrip}
      ```

      | 位置 / Location | 生命周期 / Lifecycle | SKILL.md | 路径 / Path |
      |---|---|---:|---|
      #{location_rows}

      ## 解读 / Interpretation

      `project-active` 是获批 Release 的兼容目录，不参与运行时发现；Codex、Claude Code
      和 OpenClaw 各有独立的 Global Profile，用户级别名只指向对应全局面。项目 Profile
      通过专用挂载子树加入项目原生发现根。Release、备份、供应商目录、临时目录和缓存虽然
      存储在本机，但不计入全局可见 Skills。

      `project-active` is an approved-Release compatibility catalog and is not a
      runtime discovery surface. Codex, Claude Code, and OpenClaw have separate
      Global Profiles; user aliases target only their matching global surface.
      Project Profiles enter native discovery roots through dedicated mounts.
      Releases, backups, vendor catalogs, temporary catalogs, and caches are not
      counted as globally visible Skills.
    MARKDOWN
  end

  def audit_markdown(topology)
    lines = [
      "# 本机拓扑审计 / Local Topology Audit",
      "",
      "生成时间 / Generated: `#{topology.fetch('generated_at')}`",
      ""
    ]
    {
      "错误 / Errors" => @errors,
      "警告 / Warnings" => @warnings,
      "信息 / Information" => @info
    }.each do |heading, items|
      lines << "## #{heading} (#{items.length})"
      lines << ""
      if items.empty?
        lines << "无 / None."
      else
        items.each do |item|
          lines << "- `#{item['code']}`: `#{item['subject']}` - #{item['detail']}"
        end
      end
      lines << ""
    end
    lines.join("\n")
  end

  def finding(code, subject, detail)
    { "code" => code, "subject" => subject, "detail" => detail }
  end

  def resolved_path(path)
    File.realpath(path)
  rescue Errno::ENOENT
    nil
  end

  def write_file(path, content)
    File.write(path, content)
  end

  def label(value)
    value.to_s.gsub('"', "'").gsub(/\s+/, " ")
  end

  def translated(mapping, value, fallback = nil)
    mapping.fetch(value, fallback || value)
  end

  def diagram_bilingual(value)
    label(value).sub(" / ", "<br/>")
  end

  def node_id(prefix, value)
    "#{prefix}_#{Digest::SHA1.hexdigest(value.to_s)[0, 10]}"
  end

  def print_summary(summary)
    puts "本机详细拓扑已生成 / Detailed local topology generated"
    puts "  Agent 主机 / agent hosts: #{summary['agent_hosts']}"
    puts "  活跃 Skills / active skills: #{summary['unique_active_skills']}"
    puts "  Skill 位置 / skill locations: #{summary['skill_locations']}"
    puts "  各位置 SKILL.md / SKILL.md across locations: #{summary['skill_files_across_locations']}"
    puts "  唯一物理 SKILL.md / unique physical SKILL.md: #{summary['unique_physical_skill_files']}"
    puts "  错误 / errors: #{summary['errors']}"
    puts "  警告 / warnings: #{summary['warnings']}"
  end
end

options = { root: Dir.pwd, strict: false }
OptionParser.new do |opts|
  opts.banner = "Usage: scan_local_assets.rb [options]"
  opts.on("--root PATH", "Project root") { |value| options[:root] = value }
  opts.on("--strict", "Exit 2 when audit errors are found") { options[:strict] = true }
  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end.parse!

LocalAssetCartographer.new(options).run
