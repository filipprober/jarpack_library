#!/usr/bin/env ruby
# Jarpack CLI - Package Manager für Kotlin mit Namespace Validation

require 'pathname'
require 'json'
require 'net/http'
require 'optparse'

class JavaPackageValidator
  attr_reader :errors, :warnings, :checked_files

  def initialize(src_directory = 'src', expected_prefix = nil)
    @src_directory = src_directory
    @expected_prefix = expected_prefix
    @errors = []
    @warnings = []
    @checked_files = 0
  end

  def validate!(quiet: false)
    puts "🔍 Scanning Java files in #{@src_directory}..." unless quiet

    unless Dir.exist?(@src_directory)
      @errors << "Source directory '#{@src_directory}' not found!"
      return false
    end

    java_files = Dir.glob("#{@src_directory}/**/*.{java,kt}")

    if java_files.empty?
      puts "⚠️  No Java/Kotlin files found in #{@src_directory}" unless quiet
      return true
    end

    java_files.each { |file| validate_file(file) }

    print_summary unless quiet
    @errors.empty?
  end

  def validation_summary
    {
      success: @errors.empty?,
      files_checked: @checked_files,
      errors: @errors,
      warnings: @warnings
    }
  end

  private

  def validate_file(file_path)
    @checked_files += 1

    # Package-Deklaration aus File lesen
    actual_package = extract_package_from_file(file_path)

    # Wenn ein Prefix gesetzt ist, muss eine Package-Deklaration vorhanden sein
    if @expected_prefix && (actual_package.nil? || actual_package.empty?)
      @errors << "#{file_path}: Missing package declaration! Expected package starting with '#{@expected_prefix}'"
      return
    end

    # Erwartetes Package aus Pfad ableiten
    relative_path = file_path.sub(%r{^#{Regexp.escape(@src_directory)}/}, '')
    path_package = File.dirname(relative_path).gsub('/', '.')
    path_package = '' if path_package == '.'

    # Wenn ein Prefix gesetzt ist, dann validieren wir nur ob das actual package
    # mit dem Prefix beginnt - nicht die exakte Pfad-zu-Package Entsprechung
    if @expected_prefix
      # Mit Prefix: Package muss mit Prefix beginnen, Pfad ist egal
      validate_package_prefix_only(file_path, actual_package)
      return
    end

    # Ohne Prefix: Pfad muss exakt zum Package passen
    expected_package = path_package

    # Validierungen
    validate_package_consistency(file_path, expected_package, actual_package)
  end

  def extract_package_from_file(file_path)
    begin
      content = File.read(file_path, encoding: 'UTF-8')
    rescue StandardError => e
      @errors << "Cannot read file #{file_path}: #{e.message}"
      return nil
    end

    # Package-Deklaration finden (ignoriert Kommentare)
    lines = content.lines
    package_lines = lines.reject { |line| line.strip.start_with?('//') || line.strip.start_with?('/*') }
                         .grep(/^\s*package\s+/)

    case package_lines.size
    when 0
      '' # Default package
    when 1
      # Kotlin: package abc.def (ohne Semikolon)
      # Java:   package abc.def; (mit Semikolon)
      match = if file_path.end_with?('.kt')
                package_lines.first.match(/^\s*package\s+([a-zA-Z0-9_.]+)/)
              else
                package_lines.first.match(/^\s*package\s+([a-zA-Z0-9_.]+)\s*;/)
              end
      match ? match[1] : nil
    else
      @errors << "#{file_path}: Multiple package declarations found"
      nil
    end
  end

  def validate_package_consistency(file_path, expected_package, actual_package)
    return if actual_package.nil? # Bereits als Fehler erfasst

    # Ohne Prefix: exaktes Match erforderlich
    return unless expected_package != actual_package

    @errors << "#{file_path}: Expected package '#{expected_package.empty? ? '(default)' : expected_package}', found '#{actual_package.empty? ? '(default)' : actual_package}'"
  end

  def validate_package_prefix_only(file_path, actual_package)
    return if actual_package.nil? || actual_package.empty?

    # Package muss entweder exakt dem Prefix entsprechen oder mit Prefix + '.' beginnen
    valid = actual_package == @expected_prefix || actual_package.start_with?(@expected_prefix + '.')

    return if valid

    @errors << "#{file_path}: Expected package starting with '#{@expected_prefix}', found '#{actual_package.empty? ? '(default)' : actual_package}'"
  end

  def print_summary
    puts "\n" + '=' * 60
    puts '📊 NAMESPACE VALIDATION'
    puts '=' * 60
    puts "Files checked: #{@checked_files}"
    puts "Errors: #{@errors.size}"
    puts "Warnings: #{@warnings.size}"

    if @errors.any?
      puts "\n🚨 ERRORS:"
      @errors.each { |error| puts "   ❌ #{error}" }
    end

    if @warnings.any?
      puts "\n⚠️  WARNINGS:"
      @warnings.each { |warning| puts "   ⚠️  #{warning}" }
    end

    puts "\n✅ All files passed validation!" if @errors.empty? && @warnings.empty?

    puts '=' * 60
  end
end

class JarpackCLI
  def initialize(options = {})
    @options = options
    @jarpack_config = load_jarpack_config
  end

  def validate(quiet: false)
    # Prefix aus CLI option oder jarpack.json
    namespace = @options[:prefix] || @jarpack_config['namespace']
    src_dir = @options[:src_dir] || 'src'
    validator = JavaPackageValidator.new(src_dir, namespace)

    success = validator.validate!(quiet: quiet)

    unless quiet
      if success
        puts "\n✅ All namespace validations passed!"
      else
        puts "\n❌ Validation failed! Fix the issues above before deploying."
      end
    end

    { success: success, validator: validator }
  end

  def deploy(version: nil, dry_run: false, skip_confirmations: false)
    version ||= interactive_version_selection unless skip_confirmations
    version ||= next_version

    puts "🧪 DRY RUN MODE - No changes will be made\n" if dry_run

    # Phase 1: Lokale Namespace Validation
    puts '🔍 Validating namespace structure locally...'
    validation_result = validate(quiet: true)

    unless validation_result[:success]
      puts '❌ Local validation failed:'
      validation_result[:validator].errors.each { |error| puts "   #{error}" }
      exit 1
    end
    puts '✅ Local validation passed!'

    # Bei prefix-only mode (ohne jarpack.json) können wir nicht deployen
    if @jarpack_config.empty?
      puts "❌ Cannot deploy without jarpack.json. Use 'jarpack validate' for validation only."
      exit 1
    end

    # Phase 2: Deployment Summary anzeigen
    show_deployment_summary(version)

    return if dry_run

    # Phase 3: User confirmation für Commit & Push
    unless skip_confirmations || confirm_push?
      puts '❌ Deployment cancelled by user'
      exit 0
    end

    # Phase 4: Code commiten und pushen (ohne Tag)
    commit_and_push_changes(version)

    # Phase 5: Server-side validation (simuliert)
    puts "\n🔍 Validating namespace structure on server..."
    server_validation_result = validate_at_jarpack(git_current_commit, version)

    if server_validation_result[:success]
      puts '✅ Server validation passed!'

      # Phase 6: User confirmation für Tag creation
      if skip_confirmations || confirm_tag_creation?(version)
        create_and_push_tag(version)
        finalize_deployment(version)
        puts "🎉 Successfully deployed #{version}!"
      else
        puts "⏸️  Code pushed but not tagged. Run 'jarpack deploy' again to create release."
      end
    else
      puts '❌ Server validation failed:'
      server_validation_result[:errors].each { |error| puts "   #{error}" }
      puts "\n💡 Fix the namespace issues and run 'jarpack deploy' again"
      puts '   (Your code is already pushed, just fix namespaces and retry)'
      exit 1
    end
  end

  def status
    if @jarpack_config.empty?
      puts '📊 Validation Status (Prefix Mode)'
      puts '=' * 50
      puts "Source Directory: #{@options[:src_dir] || 'src'}"
      puts "Expected Prefix: #{@options[:prefix] || 'None'}"
    else
      puts '📊 Jarpack Project Status'
      puts '=' * 50
      puts "Name: #{@jarpack_config['name']}"
      puts "Namespace: #{@options[:prefix] || @jarpack_config['namespace']}"
      puts "Current Version: #{@jarpack_config['version'] || '0.0.0'}"
      puts "Repository: #{@jarpack_config['repository'] || 'Not configured'}"
    end

    # Namespace validation status
    print "\nNamespace Status: "
    validation_result = validate(quiet: true)
    if validation_result[:success]
      puts '✅ Valid'
    else
      puts "❌ Invalid (#{validation_result[:validator].errors.size} errors)"
      validation_result[:validator].errors.first(3).each do |error|
        puts "   • #{error}"
      end
      if validation_result[:validator].errors.size > 3
        puts "   ... and #{validation_result[:validator].errors.size - 3} more"
      end
    end

    puts '=' * 50
  end

  private

  def load_jarpack_config
    unless File.exist?('jarpack.json')
      puts '❌ No jarpack.json found in current directory' unless @options[:prefix]
      return {} if @options[:prefix] # Wenn prefix gesetzt ist, ist jarpack.json optional

      exit 1
    end

    JSON.parse(File.read('jarpack.json'))
  rescue JSON::ParserError => e
    puts "❌ Invalid jarpack.json: #{e.message}" unless @options[:prefix]
    return {} if @options[:prefix]

    exit 1
  end

  def interactive_version_selection
    current = @jarpack_config['version'] || '0.0.0'

    puts "\n📈 Version Selection:"
    puts "   Current: #{current}"
    puts "   [1] Patch: #{increment_version(current, :patch)}"
    puts "   [2] Minor: #{increment_version(current, :minor)}"
    puts "   [3] Major: #{increment_version(current, :major)}"
    puts '   [4] Custom version'

    print '   Choose [1-4]: '
    choice = STDIN.gets.chomp

    case choice
    when '1' then increment_version(current, :patch)
    when '2' then increment_version(current, :minor)
    when '3' then increment_version(current, :major)
    when '4'
      print '   Enter custom version: '
      STDIN.gets.chomp
    else
      puts '❌ Invalid choice'
      exit 1
    end
  end

  def increment_version(version, type)
    parts = version.split('.').map(&:to_i)
    case type
    when :patch then [parts[0], parts[1], parts[2] + 1].join('.')
    when :minor then [parts[0], parts[1] + 1, 0].join('.')
    when :major then [parts[0] + 1, 0, 0].join('.')
    end
  end

  def next_version
    current = @jarpack_config['version'] || '0.0.0'
    increment_version(current, :patch)
  end

  def show_deployment_summary(version)
    puts "\n" + '=' * 50
    puts '📦 DEPLOYMENT SUMMARY'
    puts '=' * 50
    puts "Project: #{@jarpack_config['name']}"
    puts "Version: #{version}"
    puts "Namespace: #{@jarpack_config['namespace']}"
    puts "Repository: #{@jarpack_config['repository'] || 'Not configured'}"

    # Git status anzeigen
    if git_has_changes?
      puts "\n📝 Pending changes:"
      changes = `git status --porcelain`.lines.first(5)
      changes.each { |line| puts "   #{line.strip}" }
      if `git status --porcelain`.lines.count > 5
        puts "   ... and #{`git status --porcelain`.lines.count - 5} more files"
      end
    else
      puts "\n📝 No uncommitted changes"
    end

    # Version update preview
    current_version = @jarpack_config['version'] || '0.0.0'
    puts "\n📈 Version change: #{current_version} → #{version}" if current_version != version

    puts '=' * 50
  end

  def confirm_push?
    puts "\n❓ This will commit and push your changes to GitHub."
    print '   Continue? [y/N]: '

    response = STDIN.gets.chomp.downcase
    %w[y yes].include?(response)
  end

  def confirm_tag_creation?(version)
    puts "\n❓ Create release tag 'v#{version}' and deploy to Jarpack?"
    print '   This will make the package publicly available. [y/N]: '

    response = STDIN.gets.chomp.downcase
    %w[y yes].include?(response)
  end

  def commit_and_push_changes(version)
    puts "\n📤 Committing and pushing changes..."

    # jarpack.json mit neuer Version updaten
    update_jarpack_version(version)

    # Git operations mit Progress
    run_command_with_spinner('git add .') { 'Adding files...' }

    commit_message = "Prepare release #{version}"
    run_command_with_spinner("git commit -m '#{commit_message}'") { 'Creating commit...' }

    run_command_with_spinner('git push') { 'Pushing to GitHub...' }

    puts '✅ Changes pushed to GitHub (no tag yet)'
  end

  def create_and_push_tag(version)
    tag_name = "v#{version}"

    puts "\n🏷️  Creating release tag..."
    run_command_with_spinner("git tag #{tag_name}") { "Creating tag #{tag_name}..." }

    run_command_with_spinner('git push --tags') { 'Pushing tag to GitHub...' }

    puts "✅ Release tag #{tag_name} created and pushed"
  end

  def update_jarpack_version(version)
    @jarpack_config['version'] = version
    File.write('jarpack.json', JSON.pretty_generate(@jarpack_config))
  end

  def validate_at_jarpack(_commit_sha, _version)
    # Simulierte Server-side Validation
    # In der echten Implementation würde hier ein HTTP Request an Jarpack API gehen

    puts '   Fetching repository content...'
    sleep 0.5
    puts '   Running namespace validation...'
    sleep 0.5

    # Lokale Validation nochmals ausführen als Server-Simulation
    namespace = @options[:prefix] || @jarpack_config['namespace']
    src_dir = @options[:src_dir] || 'src'
    validator = JavaPackageValidator.new(src_dir, namespace)
    success = validator.validate!(quiet: true)

    {
      success: success,
      errors: validator.errors,
      warnings: validator.warnings
    }
  end

  def finalize_deployment(_version)
    puts "\n🚀 Finalizing deployment..."
    puts '   Registering with Jarpack registry...'
    sleep 0.5
    puts '   Building package metadata...'
    sleep 0.5
    puts '   Publishing to repository...'
    sleep 0.5
  end

  def run_command_with_spinner(command)
    print "   #{yield} "

    success = system(command + ' > /dev/null 2>&1')

    if success
      puts '✅'
    else
      puts '❌'
      puts "Command failed: #{command}"
      exit 1
    end
  end

  def git_has_changes?
    !`git status --porcelain`.strip.empty?
  end

  def git_current_commit
    `git rev-parse HEAD`.strip
  end

  def git_remote_url
    `git remote get-url origin`.strip
  end
end

# CLI Interface
if __FILE__ == $0
  options = { skip_confirmations: false, dry_run: false }

  OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} <command> [options]"
    opts.separator ''
    opts.separator 'Commands:'
    opts.separator '  validate    Check namespace structure'
    opts.separator '  deploy      Validate, commit, and deploy package'
    opts.separator '  status      Show project status'
    opts.separator ''
    opts.separator 'Options:'

    opts.on('-s', '--src DIR', 'Source directory (default: src)') do |dir|
      options[:src_dir] = dir
    end

    opts.on('-p', '--prefix PREFIX', 'Expected package prefix (e.g., com.example)') do |prefix|
      options[:prefix] = prefix
    end

    opts.on('--version VERSION', 'Specific version to deploy') do |v|
      options[:version] = v
    end

    opts.on('--yes', 'Skip confirmation prompts') do
      options[:skip_confirmations] = true
    end

    opts.on('--dry-run', 'Preview deployment without making changes') do
      options[:dry_run] = true
    end

    opts.on('-h', '--help', 'Show this help') do
      puts opts
      exit
    end
  end.parse!

  cli = JarpackCLI.new(options)
  command = ARGV[0]

  case command
  when 'validate', 'check'
    result = cli.validate
    exit(result[:success] ? 0 : 1)

  when 'deploy'
    cli.deploy(
      version: options[:version],
      dry_run: options[:dry_run],
      skip_confirmations: options[:skip_confirmations]
    )

  when 'status'
    cli.status

  else
    puts <<~HELP
      Jarpack CLI - Package Manager for Kotlin

      Usage:
        jarpack validate [options]        # Check namespace structure
        jarpack deploy [options]          # Validate, commit, tag, and deploy
        jarpack status [options]          # Show project status

      Validation Options:
        -s, --src DIR                     # Source directory (default: src)
        -p, --prefix PREFIX               # Expected package prefix (e.g., com.example)

      Deploy Options:
        --version 1.2.3                  # Specific version
        --yes                            # Skip confirmations
        --dry-run                        # Preview only

      Examples:
        jarpack validate --prefix com.example --src src/main/kotlin
        jarpack deploy --version 1.2.3 --yes
        jarpack deploy --dry-run
        jarpack status --prefix com.example
    HELP
    exit 1
  end
end
