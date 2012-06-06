# encoding: utf-8

module CarrierWaveDirect
  module Uploader

    extend ActiveSupport::Concern

    FILENAME_WILDCARD = "${filename}"

    included do
      storage :fog

      attr_accessor :success_action_redirect

      fog_credentials.keys.each do |key|
        define_method(key) do
          fog_credentials[key]
        end
      end
    end

    def direct_fog_url(options = {})
      fog_uri = CarrierWave::Storage::Fog::File.new(self, CarrierWave::Storage::Fog.new(self), nil).public_url
      if options[:with_path]
        uri = URI.parse(fog_uri)
        path = "/#{key}"
        uri.path = URI.escape(path)
        fog_uri = uri.to_s
      end
      fog_uri
    end

    def guid
      UUID.generate
    end

    def key=(k)
      @key = k
      update_version_keys(:with => @key)
    end

    def key
      @key ||= "#{store_dir}/#{guid}/#{FILENAME_WILDCARD}"
    end

    def has_key?
      @key.present? && !(@key =~ /#{Regexp.escape(FILENAME_WILDCARD)}\z/)
    end

    def acl
      fog_public ? 'public-read' : 'private'
    end

    def policy(options = {})
      options[:expiration] ||= self.class.upload_expiration
      options[:max_file_size] ||= self.class.max_file_size
      options[:extra_policy_conditions] ||= self.class.extra_policy_conditions
      options[:success_policy] ||= self.class.success_policy

      options[:success_policy] = {"success_action_redirect" => success_action_redirect} if options[:success_policy] == :redirect

      Base64.encode64(
        {
          'expiration' => Time.now.utc + options[:expiration],
          'conditions' => [
            ["starts-with", "$utf8", ""],
            ["starts-with", "$key", store_dir],
            {"bucket" => fog_directory},
            {"acl" => acl},
            options[:success_policy],
            ["content-length-range", 1, options[:max_file_size]]
          ] + options[:extra_policy_conditions]
        }.to_json
      ).gsub("\n","")
    end

    def signature
      Base64.encode64(
        OpenSSL::HMAC.digest(
          OpenSSL::Digest::Digest.new('sha1'),
          aws_secret_access_key, policy
        )
      ).gsub("\n","")
    end

    def persisted?
      false
    end

    def filename
      unless has_key?
        # Use the attached models remote url to generate a new key otherwise return nil
        remote_url = model.send("remote_#{mounted_as}_url")
        if remote_url
          sanitized_path = key_from_file(CGI::unescape(remote_url.match(/^(.*?)(\?.*)?$/)[1]))
        else
          return
        end
      end

      key_path = key.split("/")
      filename_parts = []
      filename_parts.unshift(key_path.pop)
      unique_key = key_path.pop
      filename_parts.unshift(unique_key) if unique_key
      filename_parts.join("/")
    end

    def key_regexp
      /\A#{store_dir}\/[a-f\d\-]+\/.+\.#{extension_regexp}\z/
    end

    def extension_regexp
      allowed_file_types = extension_white_list
      extension_regexp = allowed_file_types.present? && allowed_file_types.any? ?  "(#{allowed_file_types.join("|")})" : "\\w+"
    end

    def url_scheme_white_list
      nil
    end

    private

    def key_from_file(fname)
      new_key_parts = key.split("/")
      new_key_parts.pop
      new_key_parts << fname
      self.key = new_key_parts.join("/")
    end

    # Update the versions to use this key
    def update_version_keys(options)
      versions.each do |name, uploader|
        uploader.key = options[:with]
      end
    end

    # Put the version name at the end of the filename since the guid is also stored
    # e.g. guid/filename_thumb.jpg instead of CarrierWave's default: thumb_guid/filename.jpg
    def full_filename(for_file)
      extname = File.extname(for_file)
      [for_file.chomp(extname), version_name].compact.join('_') << extname
    end
  end
end
