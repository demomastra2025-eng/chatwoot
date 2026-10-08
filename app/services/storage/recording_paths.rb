# frozen_string_literal: true

# Resolves local recordings only inside tenant-owned recording directories. Absolute paths,
# traversal, symlinks and another account's tree are never accepted by storage actions.
# The path module is cohesive: tenant layout resolution and symlink-safe filesystem boundaries share helpers.
# rubocop:disable Metrics/ModuleLength
module Storage::RecordingPaths
  module_function

  def root
    Rails.root.join('storage')
  end

  def trash_root
    root.join('trash')
  end

  # This method enumerates each supported tenant-owned provider/account layout and rejects foreign numeric roots.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def account_roots(account_id, include_trash: true)
    return [] if account_id.blank?

    roots = []
    voice_root = root.join('voice-recordings')
    # safe_directory? also accepts a path that does not exist yet; a missing voice folder must not hide the trash.
    if safe_directory?(voice_root) && voice_root.directory?
      voice_root.children.each do |provider_root|
        next unless safe_directory?(provider_root)
        next if provider_root.basename.to_s.match?(/\A\d+\z/)

        account_root = provider_root.join(account_id.to_s)
        roots << account_root if safe_directory?(account_root)
      end
      account_first = voice_root.join(account_id.to_s)
      roots << account_first if safe_directory?(account_first)
    end

    if include_trash && safe_directory?(trash_root)
      trash_account_root = trash_root.join(account_id.to_s, 'recordings')
      roots << trash_account_root if safe_directory?(trash_account_root)
    end
    roots
  rescue SystemCallError
    []
  end

  # Create the account trash directory one component at a time, rejecting pre-existing symlinks.
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def prepare_trash_directory(account_id)
    account_component = Integer(account_id).to_s
    raise ArgumentError, 'Invalid account id' unless account_component.match?(/\A\d+\z/)
    raise ArgumentError, 'Storage root is not a safe directory' unless safe_directory?(root)

    current = root
    ['trash', account_component, 'recordings'].each do |component|
      current = current.join(component)
      begin
        Dir.mkdir(current.to_s)
      rescue Errno::EEXIST
        raise ArgumentError, 'Trash directory is not a safe directory' unless safe_directory?(current)
      end

      real_root = root.realpath.to_s
      real_current = current.realpath.to_s
      raise ArgumentError, 'Trash directory is outside storage root' unless real_current.start_with?("#{real_root}#{File::SEPARATOR}")
    end
    current
  end

  # Return real, regular files in only this account's layouts, deduplicated by physical inode.
  def files_for_account(account_id, include_trash: true)
    seen = {}
    paths = account_roots(account_id, include_trash: include_trash).flat_map { |tenant_root| safe_files_under(tenant_root) }
    paths.each_with_object([]) do |path, files|
      stat = File.stat(path)
      identity = [stat.dev, stat.ino]
      next if seen[identity]

      seen[identity] = true
      files << path
    rescue SystemCallError
      next
    end
  end

  # Streaming background reconciliation: stat each file once and renew the worker lease between files.
  # Directory checks retain the existing tenant/symlink boundary; callers deduplicate hard links by inode.
  def each_file_with_stat_for_account(account_id)
    return enum_for(__method__, account_id) unless block_given?

    raise IOError, 'Unsafe recording storage root' if root.exist? && !safe_directory?(root)

    # An unreadable provider directory is a failed measurement, rather than a successful zero-byte total.
    voice_root = root.join('voice-recordings')
    voice_root.children if voice_root.directory?
    directories = account_roots(account_id)
    until directories.empty?
      directory = directories.pop
      next unless safe_directory?(directory) && directory.directory?

      directory.each_child do |path|
        stat = File.lstat(path)
        next if stat.symlink?

        if stat.directory?
          directories << path
        elsif stat.file? && safe_existing_path_under_root?(path)
          yield path, stat
        end
      rescue Errno::ENOENT
        next
      end
    end
  end

  # Produce tenant-relative aliases for a real file so legacy basename references are checked
  # against the same physical recording as provider/account-qualified references.
  def reference_aliases(path, account_id:, allow_missing: false)
    candidate = Pathname.new(path.to_s).expand_path.cleanpath
    tenant_root = account_roots(account_id, include_trash: true).find do |base|
      reference_path_inside_root?(candidate, base, account_id, allow_missing)
    end
    return [] unless tenant_root

    [
      candidate.to_s,
      candidate.relative_path_from(root.expand_path).to_s,
      candidate.relative_path_from(tenant_root.expand_path).to_s,
      candidate.basename.to_s
    ].uniq.reject(&:blank?)
  rescue ArgumentError, SystemCallError
    []
  end

  def physical_identity(ref, account_id:)
    path = tenant_path_for_reference(ref, account_id: account_id)
    return unless path

    stat = File.stat(path.to_s)
    [stat.dev, stat.ino]
  rescue SystemCallError
    nil
  end

  def same_physical_file?(left_ref, right_ref, account_id:)
    left_identity = physical_identity(left_ref, account_id: account_id)
    return false unless left_identity

    left_identity == physical_identity(right_ref, account_id: account_id)
  end

  # Match a saved alias to original, retained, and trash paths. If a legacy suffix cannot
  # be resolved uniquely, keep the file unless a qualified reference proves another inode.
  def reference_matches_paths?(reference, paths, account_id:, aliases: nil, qualified_references: [], conservative: true)
    value = reference.to_s
    keys = aliases || paths.flat_map do |path|
      reference_aliases(path, account_id: account_id, allow_missing: !File.exist?(path.to_s))
    end
    return false unless keys.include?(value)

    source_ids = paths.filter_map { |path| physical_identity(path, account_id: account_id) }.uniq
    reference_id = physical_identity(value, account_id: account_id)
    return source_ids.include?(reference_id) if reference_id

    qualified_ids = Array(qualified_references).map(&:to_s)
      .select { |candidate| qualified_reference?(candidate) }
      .filter_map { |candidate| physical_identity(candidate, account_id: account_id) }.uniq
    return false if source_ids.any? && qualified_ids.any? && (source_ids & qualified_ids).empty?
    return true if source_ids.any? && qualified_ids.any?

    conservative
  rescue ArgumentError, SystemCallError
    false
  end

  def qualified_reference?(reference)
    path = Pathname.new(reference.to_s)
    path.absolute? || path.each_filename.count > 1
  rescue ArgumentError
    false
  end

  # A tenant/basename advisory key is intentionally conservative: it stays identical for qualified,
  # absolute and legacy references before and after an atomic publish or trash move. Provider roots
  # can contain same-named files, so reference rewrites still require physical-file identity checks.
  def canonical_lock_identity(ref, account_id:)
    value = ref.to_s
    path = Pathname.new(value)
    return "account:#{account_id}:opaque:#{value}" if value.blank? || path.each_filename.any? { |part| part == '..' || part == '.' }

    basename = path.basename.to_s
    return "account:#{account_id}:opaque:#{value}" if basename.blank? || %w[. ..].include?(basename)

    "account:#{account_id}:basename:#{basename}"
  rescue ArgumentError
    "account:#{account_id}:opaque:#{ref}"
  end

  def reference_path_inside_root?(candidate, base, account_id, allow_missing)
    return contained?(candidate, base) unless allow_missing

    lexical_path = candidate.to_s.start_with?("#{base.expand_path.cleanpath}#{File::SEPARATOR}")
    return false unless lexical_path
    return contained?(candidate, base) if File.exist?(candidate.to_s) || File.symlink?(candidate.to_s)

    within_account?(candidate, account_id: account_id, include_trash: true)
  end
  private_class_method :reference_path_inside_root?

  # Resolution validates tenant roots before it permits the legacy basename fallback.
  def resolve(ref, account_id: nil)
    return if account_id.blank?

    resolve_in_roots(ref, account_roots(account_id, include_trash: false))
  rescue ArgumentError, SystemCallError
    nil
  end

  def resolve_trash(ref, account_id:)
    return if account_id.blank? || ref.blank?

    path = Pathname.new(ref.to_s)
    return unless path.absolute?

    trash_account_root = trash_root.join(Integer(account_id).to_s, 'recordings')
    path if contained?(path, trash_account_root)
  rescue ArgumentError, SystemCallError
    nil
  end

  # Existing file containment is account-scoped and rejects symlinks in every path component.
  # Lexical, realpath and every-ancestor checks are kept together at this filesystem security boundary.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def contained?(path, base)
    path = Pathname.new(path.to_s).expand_path.cleanpath
    base = Pathname.new(base.to_s).expand_path.cleanpath
    return false unless safe_directory?(base) && safe_existing_path_under_root?(path) && path.file?
    return false unless path.to_s.start_with?("#{base}#{File::SEPARATOR}")

    real_base = base.realpath.to_s
    current = path
    loop do
      return false if File.lstat(current.to_s).symlink?

      real_current = current.realpath.to_s
      return false unless real_current == real_base || real_current.start_with?("#{real_base}#{File::SEPARATOR}")
      break if current == base

      current = current.dirname
      return false unless current.to_s.start_with?("#{base}#{File::SEPARATOR}") || current == base
    end
    true
  rescue SystemCallError
    false
  end

  # Validate a not-yet-existing restore path against the account's known storage layouts.
  # Every existing ancestor is checked, including the tenant root, before callers create directories.
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # Restore destinations must pass lexical, tenant-root and all-existing-ancestor checks before creation.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def within_account?(path, account_id:, include_trash: false)
    raw_path = Pathname.new(path.to_s)
    return false unless raw_path.absolute?
    return false if raw_path.each_filename.any? { |part| part == '..' || part == '.' }
    return false if File.exist?(raw_path.to_s) || File.symlink?(raw_path.to_s)

    candidate = raw_path.expand_path.cleanpath
    account_roots(account_id, include_trash: include_trash).any? do |tenant_root|
      base = tenant_root.expand_path.cleanpath
      next false unless candidate.to_s.start_with?("#{base}#{File::SEPARATOR}")
      next false unless safe_directory?(base)

      real_base = base.realpath.to_s
      relative = candidate.relative_path_from(base)
      current = base
      safe = true
      relative.each_filename do |part|
        current = current.join(part)
        break unless File.exist?(current.to_s) || File.symlink?(current.to_s)

        if File.lstat(current.to_s).symlink?
          safe = false
          break
        end
        real_current = current.realpath.to_s
        unless real_current == real_base || real_current.start_with?("#{real_base}#{File::SEPARATOR}")
          safe = false
          break
        end
      end
      safe
    rescue SystemCallError, ArgumentError
      false
    end
  rescue ArgumentError, SystemCallError
    false
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # Reject missing ancestors and symlinks from the trusted storage root down to the candidate.
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def safe_existing_path_under_root?(path)
    candidate = Pathname.new(path.to_s).expand_path.cleanpath
    trusted_root = root.expand_path.cleanpath
    return false unless safe_directory?(trusted_root)
    return false unless candidate.to_s.start_with?("#{trusted_root}#{File::SEPARATOR}")

    current = trusted_root
    relative = candidate.relative_path_from(trusted_root)
    relative.each_filename do |component|
      current = current.join(component)
      return false unless File.exist?(current.to_s) || File.symlink?(current.to_s)

      stat = File.lstat(current.to_s)
      return false if stat.symlink?
      return false unless current == candidate || stat.directory?
    end
    true
  rescue ArgumentError, SystemCallError
    false
  end
  private_class_method :safe_existing_path_under_root?
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # Validate an existing regular file under any supported tenant layout, including account trash.
  def contained_in_account?(path, account_id:, include_trash: true)
    account_roots(account_id, include_trash: include_trash).any? { |base| contained?(path, base) }
  end

  def tenant_path_for_reference(ref, account_id:)
    resolve_in_roots(ref, account_roots(account_id, include_trash: true))
  rescue ArgumentError, SystemCallError
    nil
  end
  private_class_method :tenant_path_for_reference

  def resolve_in_roots(ref, tenant_roots)
    return if ref.to_s.blank?

    relative = Pathname.new(ref.to_s)
    return if relative.each_filename.any? { |part| part == '..' || part == '.' }
    return relative if relative.absolute? && tenant_roots.any? { |base| contained?(relative, base) }
    return if relative.absolute?

    exact_candidates = [root.join(relative)] + tenant_roots.map { |base| base.join(relative) }
    exact = unique_contained_file(exact_candidates, tenant_roots)
    return exact if exact
    return unless relative.each_filename.count == 1

    basename_candidates = tenant_roots.flat_map { |base| safe_files_under(base) }
                                     .select { |path| path.basename.to_s == relative.basename.to_s }
    unique_contained_file(basename_candidates, tenant_roots)
  end
  private_class_method :resolve_in_roots

  def unique_contained_file(paths, tenant_roots)
    identities = paths.each_with_object({}) do |path, matches|
      next unless tenant_roots.any? { |base| contained?(path, base) }

      stat = File.stat(path.to_s)
      matches[[stat.dev, stat.ino]] ||= path
    rescue SystemCallError
      next
    end
    identities.values.one? ? identities.values.first : nil
  end
  private_class_method :unique_contained_file

  def lexical_path_under_account_root?(path, account_id)
    candidate = Pathname.new(path.to_s).expand_path.cleanpath
    account_roots(account_id, include_trash: true).any? do |base|
      candidate.to_s.start_with?("#{base.expand_path.cleanpath}#{File::SEPARATOR}")
    end
  end
  private_class_method :lexical_path_under_account_root?

  def safe_files_under(tenant_root)
    return [] unless safe_directory?(tenant_root)

    tenant_root.glob('**/*').filter_map do |path|
      path if contained?(path, tenant_root)
    rescue SystemCallError
      nil
    end
  end
  private_class_method :safe_files_under

  # Validate every existing directory ancestor beneath the trusted storage root.
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def safe_directory?(path)
    candidate = Pathname.new(path.to_s).expand_path.cleanpath
    trusted_root = root.expand_path.cleanpath
    return false unless candidate == trusted_root || candidate.to_s.start_with?("#{trusted_root}#{File::SEPARATOR}")
    return false unless safe_trusted_root?(trusted_root)

    current = trusted_root
    relative = candidate.relative_path_from(trusted_root)
    relative.each_filename do |component|
      current = current.join(component)
      break unless File.exist?(current.to_s) || File.symlink?(current.to_s)

      stat = File.lstat(current.to_s)
      return false if stat.symlink?
      return false unless stat.directory?
    end
    true
  rescue ArgumentError, SystemCallError
    false
  end
  private_class_method :safe_directory?
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def safe_trusted_root?(trusted_root)
    return false unless trusted_root.directory?
    return false if File.lstat(trusted_root.to_s).symlink?

    trusted_root.realpath == trusted_root
  rescue SystemCallError
    false
  end
  private_class_method :safe_trusted_root?
  # rubocop:enable Metrics/ModuleLength
end
