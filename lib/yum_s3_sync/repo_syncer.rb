#!/usr/bin/env ruby

require 'yum_s3_sync'
require 'parallel'

module YumS3Sync
  class RepoSyncer
    def initialize(source_base, target_bucket, target_base, keep = false, dry_run = false)
      @source_base = source_base
      @target_bucket = target_bucket
      @target_base = target_base
      @keep = keep
      @dry_run = dry_run
    end

    def sync
      http_downloader = YumS3Sync::HTTPDownloader.new(@source_base)
      source_repository = YumS3Sync::YumRepository.new(http_downloader)

      s3_downloader = YumS3Sync::S3Downloader.new(@target_bucket, @target_base)
      dest_repository = YumS3Sync::YumRepository.new(s3_downloader)

      s3_uploader = YumS3Sync::S3Uploader.new(@target_bucket, @target_base, @dry_run)

      s3_file_lister = YumS3Sync::S3FileLister.new(@target_bucket, @target_base)
      s3_deleter = YumS3Sync::S3Deleter.new(@target_bucket, @target_base, @dry_run)

      new_packages = source_repository.compare(dest_repository)

      metadata = []
      new_metadata = false
      source_repository.metadata.each do |type, file|
        if !dest_repository.metadata[type] || dest_repository.metadata[type][:checksum] != file[:checksum]
          new_metadata = true
        end

        metadata.push file[:href]
      end

      new_packages.each do |package|
        if @keep && ! s3_uploader.file_exists?(package)
          s3_uploader.upload(package, http_downloader.download(package))
        end
      end

      if !dest_repository.exists? || !new_packages.empty? || new_metadata
        source_repository.metadata.each do |type, file|
          s3_uploader.upload(file[:href], file[:file])
        end
      end

      file_names = s3_file_lister.list

      puts "Locating removed files"
      file_names.each do |filename|
        if !source_repository.packages[filename] && !metadata.include?(filename)
          s3_deleter.delete(filename)
        end
      end

      puts "Locating missing files"
      source_repository.packages.each do |package, data|
        unless file_names.include? package
          s3_uploader.upload(package, http_downloader.download(package))
        end
      end

    end
  end
end
