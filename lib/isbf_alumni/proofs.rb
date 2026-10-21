# frozen_string_literal: true

require "fileutils"
require "image_magick"
require "securerandom"
require "tempfile"

module IsbfAlumni
  module Proofs
    SOURCE_MAX_BYTES = 10_000_000
    MAX_BYTES = 1_000_000
    MAX_COUNT = 5
    MAX_TOTAL = 25
    MAX_PIXELS = 40_000_000
    PROCESSING_SECONDS = 30
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    FORMATS = %w[JPEG PNG WEBP HEIC HEIF].freeze

    class << self
      def valid_id?(id)
        id.is_a?(String) && UUID.match?(id)
      end

      def upload!(application, uploaded_file)
        original = uploaded_file.tempfile if uploaded_file.is_a?(ActionDispatch::Http::UploadedFile)
        validate_source!(original)
        id = SecureRandom.uuid
        destination = nil
        published = false
        application.with_lock do
          ensure_editable!(application)
          entries = Array(application.proofs).map(&:dup)
          if entries.count { |entry| !entry["removed_at"] && !entry["bound"] && !Array(application.submitted_proof_ids).include?(entry["id"]) } >= MAX_COUNT || entries.length >= MAX_TOTAL
            raise RegistrationError.new(:proof_limit)
          end
          destination = path(id)
          output = compress!(original.path)
          begin
            DistributedMutex.synchronize("isbf-alumni-proof-storage") do
              ensure_storage_capacity!(File.size(output.path))
              raise RegistrationError.new(:invalid_proof) if File.exist?(destination)
              File.rename(output.path, destination)
              published = true
              File.chmod(0o600, destination)
              entry = { "id" => id, "bytes" => File.size(destination), "created_at" => Time.now.utc.iso8601 }
              application.update!(proofs: entries + [entry])
              { id: id, url: "/isbf/alumni/application-proofs/#{id}", bytes: entry["bytes"] }
            end
          ensure
            output.close!
          end
        end
      rescue RegistrationError
        File.delete(destination) if published && destination && File.file?(destination)
        raise
      rescue StandardError
        File.delete(destination) if published && destination && File.file?(destination)
        raise RegistrationError.new(:invalid_proof), cause: nil
      ensure
        original&.close!
      end

      def download(application, id)
        entry = Array(application.proofs).find { |item| item["id"] == id && !item["removed_at"] }
        raise Discourse::NotFound unless entry
        target = path(id)
        raise Discourse::NotFound unless File.file?(target)
        target
      end

      def remove!(application, id)
        target = nil
        application.with_lock do
          ensure_editable!(application)
          if Array(application.submitted_proof_ids).include?(id)
            raise RegistrationError.new(:invalid_proof)
          end
          entries = Array(application.proofs).map(&:dup)
          entry = entries.find { |item| item["id"] == id && !item["removed_at"] }
          raise Discourse::NotFound unless entry
          raise RegistrationError.new(:invalid_proof) if entry["bound"]
          target = path(id)
          entry["removed_at"] = Time.now.utc.iso8601
          application.update!(proofs: entries)
        end
        File.delete(target) if target && File.file?(target)
        true
      end

      def path(id)
        raise Discourse::NotFound unless id.is_a?(String) && UUID.match?(id)
        directory = root
        target = File.join(directory, "#{id}.jpg")
        raise Discourse::NotFound if File.symlink?(target)
        if File.exist?(target) && File.realpath(target) != target
          raise Discourse::NotFound
        end
        target
      end

      private

      def root
        directory = if Rails.env.test?
          Rails.root.join("tmp", "isbf-alumni-private-test").to_s
        else
          "/shared/isbf-alumni-private"
        end
        FileUtils.mkdir_p(directory, mode: 0o700)
        raise Discourse::NotFound if File.symlink?(directory) || File.realpath(directory) != File.expand_path(directory)
        File.chmod(0o700, directory)
        directory
      end

      def ensure_editable!(application)
        raise RegistrationError.new(:invalid_proof) unless %w[draft rejected].include?(application.status.to_s)
      end

      def validate_source!(original)
        unless original && File.file?(original.path) && File.size(original.path).between?(1, SOURCE_MAX_BYTES)
          raise RegistrationError.new(:invalid_proof)
        end
        header = File.binread(original.path, 64)
        jpeg = header.start_with?("\xFF\xD8\xFF".b)
        png = header.start_with?("\x89PNG\r\n\x1A\n".b)
        webp = header.start_with?("RIFF") && header.byteslice(8, 4) == "WEBP"
        heif = header.byteslice(4, 4) == "ftyp" && header.byteslice(8, 56).to_s.scan(/.{4}/m).any? { |brand| %w[heic heix hevc hevx heim heis hevm hevs mif1 msf1].include?(brand) }
        raise RegistrationError.new(:invalid_proof) unless jpeg || png || webp || heif
      end

      def ensure_storage_capacity!(additional_bytes)
        directory = root
        stored_bytes = Dir.children(directory).sum do |filename|
          next 0 unless filename.end_with?(".jpg") && valid_id?(filename.delete_suffix(".jpg"))
          target = path(filename.delete_suffix(".jpg"))
          File.file?(target) ? File.size(target) : 0
        end
        quota = SiteSetting.isbf_alumni_proof_storage_mb.to_i * 1024 * 1024
        raise RegistrationError.new(:proof_storage_full) if quota <= 0 || stored_bytes + additional_bytes > quota
      end

      def execute(deadline, tool, *arguments, read:, write: [])
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise RegistrationError.new(:invalid_proof) if remaining <= 0
        method = tool == "identify" ? :identify : :magick
        ImageMagick.public_send(method, *arguments, operation: "isbf-alumni-proof", read: read, write: write, timeout: [remaining, 15].min)
      end

      def compress!(source)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PROCESSING_SECONDS
        limits = ["-limit", "memory", "96MiB", "-limit", "map", "192MiB", "-limit", "disk", "256MiB", "-limit", "thread", "1"]
        identified = execute(deadline, "identify", *limits, "-ping", "-format", "%m %w %h", "#{source}[0]", read: [source]).to_s.split
        format, width, height = identified
        width = Integer(width, exception: false)
        height = Integer(height, exception: false)
        unless FORMATS.include?(format) && width && height && width.positive? && height.positive? && width * height <= MAX_PIXELS
          raise RegistrationError.new(:invalid_proof)
        end
        output = Tempfile.new(["proof-", ".jpg"], root)
        output.close
        [[2560, 85], [2560, 75], [2560, 65], [1920, 75], [1280, 75]].each do |edge, quality|
          execute(deadline, "convert", *limits, "#{source}[0]", "-auto-orient", "-background", "white", "-alpha", "remove", "-alpha", "off", "-colorspace", "sRGB", "-strip", "-resize", "#{edge}x#{edge}>", "-quality", quality.to_s, "JPEG:#{output.path}", read: [source], write: [output.path])
          next unless File.size(output.path).between?(1, MAX_BYTES)
          verified = execute(deadline, "identify", *limits, "-ping", "-format", "%m %w %h", output.path, read: [output.path]).to_s.split
          unless verified[0] == "JPEG" && File.binread(output.path, 3) == "\xFF\xD8\xFF".b
            raise RegistrationError.new(:invalid_proof)
          end
          File.chmod(0o600, output.path)
          return output
        end
        raise RegistrationError.new(:invalid_proof)
      rescue StandardError
        output&.close!
        raise RegistrationError.new(:invalid_proof), cause: nil
      end
    end
  end
end
