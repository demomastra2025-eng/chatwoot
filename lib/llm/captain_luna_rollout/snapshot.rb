# frozen_string_literal: true

# The rollback snapshot of the Luna 6 cut-over as a JSON file. It holds account ids and the old model ids only (no
# personal data), is created exclusively for its owner (mode 0600), never overwrites a file and is read back and
# compared before the cut-over may rely on it.
class Llm::CaptainLunaRollout::Snapshot
  class Error < StandardError; end

  FILE_MODE = 0o600

  class << self
    def write(plan, path)
      path = Pathname.new(path.to_s)
      expected = JSON.parse(JSON.generate(plan))
      file = open_exclusively(path)
      begin
        file.chmod(FILE_MODE)
        file.write(JSON.pretty_generate(expected))
        file.close
        verify!(path, expected)
      rescue StandardError
        file.close unless file.closed?
        path.delete if path.exist?
        raise
      end
      path
    end

    def read(path)
      path = Pathname.new(path.to_s)
      raise Error, "Snapshot #{path} does not exist" unless path.file?

      ensure_private!(path)
      JSON.parse(path.read)
    rescue JSON::ParserError
      raise Error, "Snapshot #{path} is not valid JSON"
    end

    private

    def open_exclusively(path)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, FILE_MODE)
    rescue Errno::EEXIST
      raise Error, "Snapshot #{path} already exists"
    end

    def verify!(path, expected)
      raise Error, "Snapshot #{path} does not match the plan that was written" unless read(path) == expected
    end

    def ensure_private!(path)
      mode = path.stat.mode & 0o777
      return if mode == FILE_MODE

      raise Error, "Snapshot #{path} must have mode 0600 (it has #{format('%04o', mode)})"
    end
  end
end
