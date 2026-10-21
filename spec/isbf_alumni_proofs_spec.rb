# frozen_string_literal: true

require "rails_helper"

RSpec.describe IsbfAlumni::Proofs do
  let(:application) do
    Class.new do
      attr_accessor :status, :proofs, :submitted_proof_ids

      def initialize
        @status = "draft"
        @proofs = []
        @submitted_proof_ids = []
      end

      def with_lock
        yield
      end

      def update!(attributes)
        attributes.each { |key, value| public_send("#{key}=", value) }
      end
    end.new
  end

  before do
    SiteSetting.isbf_alumni_proof_storage_mb = 1024
  end

  after do
    Array(application.proofs).each do |entry|
      target = described_class.path(entry["id"])
      File.delete(target) if File.file?(target)
    end
  end

  def generated_upload(format = "png", filename: "proof.png", orientation: false)
    file = Tempfile.new(["alumni-source-", ".#{format}"])
    file.close
    Discourse::Utils.execute_command("convert", "-size", "40x20", "xc:white", "-set", "comment", "private original metadata", file.path, timeout: 15)
    if orientation
      bytes = File.binread(file.path)
      tiff = "II".b + [42, 8, 1, 0x0112, 3, 1, 6, 0].pack("vVvvvVVV")
      exif = "Exif\x00\x00".b + tiff
      File.binwrite(file.path, bytes[0, 2] + "\xFF\xE1".b + [exif.bytesize + 2].pack("n") + exif + bytes[2..])
    end
    ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: filename, type: "application/octet-stream")
  end

  def arbitrary_upload(content)
    file = Tempfile.new("alumni-invalid-")
    file.binmode
    file.write(content)
    file.flush
    ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: "proof.jpg", type: "image/jpeg")
  end

  it "compresses real PNG and JPEG bytes to private JPEGs regardless of filename" do
    %w[png jpg].each do |format|
      upload = generated_upload(format, filename: "untrusted.pdf")
      original = upload.tempfile.path
      metadata = described_class.upload!(application, upload)
      target = described_class.download(application, metadata[:id])
      expect(metadata[:bytes]).to be_between(1, 1_000_000)
      expect(metadata[:url]).to eq("/isbf/alumni/application-proofs/#{metadata[:id]}")
      expect(File.binread(target, 3)).to eq("\xFF\xD8\xFF".b)
      expect(File.exist?(original)).to eq(false)
      expect(File.stat(target).mode & 0o777).to eq(0o600)
      expect(File.stat(File.dirname(target)).mode & 0o777).to eq(0o700)
      expect(target).to start_with(Rails.root.join("tmp", "isbf-alumni-private-test").to_s)
    end
  end

  it "applies EXIF orientation and strips source comments and metadata" do
    metadata = described_class.upload!(application, generated_upload("jpg", orientation: true))
    target = described_class.download(application, metadata[:id])
    info = Discourse::Utils.execute_command("identify", "-format", "%w %h|%c|%[EXIF:*]", target, timeout: 15)
    expect(info).to start_with("20 40||")
    expect(info).not_to include("private original metadata", "Orientation")
  end

  it "decodes genuine native HEIC fixtures and produces small JPEG previews" do
    %w[heif-color-grid-8bit.heic heif-color-grid-rotated.heic].each do |name|
      source = file_from_fixtures(name)
      file = Tempfile.new(["alumni-heic-", ".heic"])
      file.binmode
      file.write(File.binread(source.path))
      file.flush
      upload = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: name, type: "image/heic")
      metadata = described_class.upload!(application, upload)
      target = described_class.download(application, metadata[:id])
      expect(File.binread(target, 3)).to eq("\xFF\xD8\xFF".b)
      expect(File.size(target)).to be_between(1, 1_000_000)
    end
  end

  it "rejects a truncated HEIC payload without keeping its source" do
    source = file_from_fixtures("heif-truncated-payload.heic")
    file = Tempfile.new(["alumni-invalid-heic-", ".heic"])
    file.binmode
    file.write(File.binread(source.path))
    file.flush
    upload = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: "proof.heic", type: "image/heic")
    expect { described_class.upload!(application, upload) }.to raise_error(IsbfAlumni::RegistrationError)
  end

  it "rejects unsupported headers before decoding and destroys original temporary files" do
    upload = arbitrary_upload("<svg>not an image</svg>")
    original = upload.tempfile.path
    expect(ImageMagick).not_to receive(:identify)
    expect(ImageMagick).not_to receive(:magick)
    expect { described_class.upload!(application, upload) }.to raise_error(IsbfAlumni::RegistrationError)
    expect(File.exist?(original)).to eq(false)
    expect(application.proofs).to be_empty
  end

  it "rejects sources larger than ten million bytes and malformed claimed images" do
    oversized = arbitrary_upload("\xFF\xD8\xFF".b)
    oversized.tempfile.truncate(10_000_001)
    expect { described_class.upload!(application, oversized) }.to raise_error(IsbfAlumni::RegistrationError)
    expect { described_class.upload!(application, arbitrary_upload("\x89PNG\r\n\x1A\ninvalid".b)) }.to raise_error(IsbfAlumni::RegistrationError)
    expect(application.proofs).to be_empty
  end

  it "does not persist conversion errors, stderr or temporary file paths" do
    upload = generated_upload
    allow(ImageMagick).to receive(:identify).and_raise(StandardError, "private-path and command stderr")
    expect { described_class.upload!(application, upload) }.to raise_error(IsbfAlumni::RegistrationError) { |error| expect(error.message).not_to include("private-path", "stderr") }
    expect(application.proofs).to be_empty
  end

  it "rejects decoded images above the forty-megapixel limit" do
    upload = generated_upload
    allow(ImageMagick).to receive(:identify).and_return("PNG 10000 10000")
    expect { described_class.upload!(application, upload) }.to raise_error(IsbfAlumni::RegistrationError)
  end

  it "guards UUID paths and symlinks and never serves another application's files" do
    expect { described_class.path("../outside") }.to raise_error(Discourse::NotFound)
    metadata = described_class.upload!(application, generated_upload)
    expect { described_class.download(application, SecureRandom.uuid) }.to raise_error(Discourse::NotFound)
    expect { described_class.download(application, "../outside") }.to raise_error(Discourse::NotFound)
    target = described_class.path(SecureRandom.uuid)
    File.symlink(described_class.path(metadata[:id]), target)
    expect { described_class.path(File.basename(target, ".jpg")) }.to raise_error(Discourse::NotFound)
  ensure
    File.unlink(target) if target && File.symlink?(target)
  end

  it "retains quota tombstones while removing only previously unsubmitted proofs" do
    metadata = described_class.upload!(application, generated_upload)
    target = described_class.path(metadata[:id])
    expect(described_class.remove!(application, metadata[:id])).to eq(true)
    expect(File.exist?(target)).to eq(false)
    expect(application.proofs.first).to have_key("removed_at")
    expect { described_class.download(application, metadata[:id]) }.to raise_error(Discourse::NotFound)
    metadata = described_class.upload!(application, generated_upload)
    application.proofs.find { |entry| entry["id"] == metadata[:id] }["bound"] = true
    application.submitted_proof_ids = []
    application.status = "rejected"
    expect { described_class.remove!(application, metadata[:id]) }.to raise_error(IsbfAlumni::RegistrationError)
  end

  it "allows a fresh proof after rejection while retaining bound historical files" do
    application.proofs = Array.new(5) { { "id" => SecureRandom.uuid, "bound" => true } }
    application.status = "rejected"
    metadata = described_class.upload!(application, generated_upload)
    expect(application.proofs.length).to eq(6)
    expect(described_class.download(application, metadata[:id])).to be_present
  end

  it "serializes final publication and enforces the global private storage budget" do
    upload = generated_upload
    expect(DistributedMutex).to receive(:synchronize).with("isbf-alumni-proof-storage").and_call_original
    allow(SiteSetting).to receive(:isbf_alumni_proof_storage_mb).and_return(0)
    expect { described_class.upload!(application, upload) }.to raise_error(IsbfAlumni::RegistrationError)
    expect(application.proofs).to be_empty
  end

  it "restricts native decoding to the exact source and private output paths" do
    upload = generated_upload
    original = upload.tempfile.path
    allow(ImageMagick).to receive(:identify).and_call_original
    conversion_calls = []
    allow(ImageMagick).to receive(:magick).and_wrap_original do |method, *arguments, **options|
      conversion_calls << options
      method.call(*arguments, **options)
    end
    described_class.upload!(application, upload)
    expect(ImageMagick).to have_received(:identify).with(any_args, operation: "isbf-alumni-proof", read: [original], write: [], timeout: be <= 15).at_least(:once)
    expect(conversion_calls).not_to be_empty
    conversion_calls.each do |options|
      expect(options[:operation]).to eq("isbf-alumni-proof")
      expect(options[:read]).to eq([original])
      expect(options[:write].length).to eq(1)
      expect(options[:write].first).to start_with(Rails.root.join("tmp", "isbf-alumni-private-test").to_s + "/proof-")
      expect(options[:timeout]).to be_between(0, 15)
    end
  end

  it "bounds uploads and disallows mutation after submission" do
    application.proofs = Array.new(25) { { "id" => SecureRandom.uuid, "removed_at" => Time.now.utc.iso8601 } }
    expect { described_class.upload!(application, generated_upload) }.to raise_error(IsbfAlumni::RegistrationError)
    application.proofs = []
    application.status = "pending"
    expect { described_class.upload!(application, generated_upload) }.to raise_error(IsbfAlumni::RegistrationError)
  end
end
