# frozen_string_literal: true

require "dependabot/metadata_finders"
require "dependabot/pull_request_creator"

module Dependabot
  class PullRequestCreator
    class MessageBuilder
      SEMANTIC_PREFIXES = %w(build chore ci docs feat fix perf refactor style
                             test).freeze
      attr_reader :repo_name, :dependencies, :files, :github_client,
                  :pr_message_footer, :author_details

      def initialize(repo_name:, dependencies:, files:, github_client:,
                     pr_message_footer: nil, author_details: nil)
        @dependencies = dependencies
        @files = files
        @repo_name = repo_name
        @github_client = github_client
        @pr_message_footer = pr_message_footer
        @author_details = author_details
      end

      def pr_name
        return library_pr_name if library?
        application_pr_name
      end

      def pr_message
        return commit_message_body unless pr_message_footer
        commit_message_body + "\n\n#{pr_message_footer}"
      end

      def commit_message
        message =  pr_name + "\n\n"
        message += commit_message_body
        message += "\n\n" + signoff_message if signoff_message
        message
      end

      private

      def commit_message_body
        return requirement_pr_message if library?
        version_pr_message
      end

      def signoff_message
        return unless author_details.is_a?(Hash)
        return unless author_details[:name] && author_details[:email]
        "Signed-off-by: #{author_details[:name]} <#{author_details[:email]}>"
      end

      def library_pr_name
        pr_name = using_semantic_commit_messages? ? "build: update " : "Update "

        pr_name +=
          if dependencies.count == 1
            "#{dependencies.first.name} requirement to "\
            "#{new_library_requirement(dependencies.first)}"
          else
            names = dependencies.map(&:name)
            "requirements for #{names[0..-2].join(', ')} and #{names[-1]}"
          end

        return pr_name if files.first.directory == "/"

        pr_name + " in #{files.first.directory}"
      end

      def application_pr_name
        pr_name = using_semantic_commit_messages? ? "build: bump " : "Bump "

        pr_name +=
          if dependencies.count == 1
            dependency = dependencies.first
            "#{dependency.name} from #{previous_version(dependency)} "\
            "to #{new_version(dependency)}"
          else
            names = dependencies.map(&:name)
            "#{names[0..-2].join(', ')} and #{names[-1]}"
          end

        return pr_name if files.first.directory == "/"

        pr_name + " in #{files.first.directory}"
      end

      def requirement_pr_message
        msg = "Updates the requirements on "

        msg +=
          if dependencies.count == 1
            "#{dependency_links.first} "
          else
            "#{dependency_links[0..-2].join(', ')} and #{dependency_links[-1]} "
          end

        msg += "to permit the latest version."
        msg + metadata_links
      end

      def version_pr_message
        if dependencies.count == 1
          dependency = dependencies.first
          msg = "Bumps #{dependency_links.first} "\
                "from #{previous_version(dependency)} "\
                "to #{new_version(dependency)}."
          if switching_from_ref_to_release?(dependency)
            msg += " This release includes the previously tagged commit."
          end
        else
          msg = "Bumps #{dependency_links[0..-2].join(', ')} "\
                "and #{dependency_links[-1]}. These "\
                "dependencies needed to be updated together."
        end

        msg + metadata_links
      end

      def dependency_links
        dependencies.map do |dependency|
          if source_url(dependency)
            "[#{dependency.name}](#{source_url(dependency)})"
          elsif homepage_url(dependency)
            "[#{dependency.name}](#{homepage_url(dependency)})"
          else
            dependency.name
          end
        end
      end

      def metadata_links
        if dependencies.count == 1
          return metadata_links_for_dep(dependencies.first)
        end

        dependencies.map do |dep|
          "\n\nUpdates `#{dep.name}` from #{previous_version(dep)} to "\
          "#{new_version(dep)}"\
          "#{metadata_links_for_dep(dep)}"
        end.join
      end

      def metadata_links_for_dep(dep)
        msg = ""
        msg += "\n- [Release notes](#{release_url(dep)})" if release_url(dep)
        msg += "\n- [Changelog](#{changelog_url(dep)})" if changelog_url(dep)
        msg += "\n- [Upgrade guide](#{upgrade_url(dep)})" if upgrade_url(dep)
        msg += "\n- [Commits](#{commits_url(dep)})" if commits_url(dep)
        msg
      end

      def release_url(dependency)
        metadata_finder(dependency).release_url
      end

      def changelog_url(dependency)
        metadata_finder(dependency).changelog_url
      end

      def upgrade_url(dependency)
        metadata_finder(dependency).upgrade_guide_url
      end

      def commits_url(dependency)
        metadata_finder(dependency).commits_url
      end

      def source_url(dependency)
        metadata_finder(dependency).source_url
      end

      def homepage_url(dependency)
        metadata_finder(dependency).homepage_url
      end

      def metadata_finder(dependency)
        @metadata_finder ||= {}
        @metadata_finder[dependency.name] ||=
          MetadataFinders.
          for_package_manager(dependency.package_manager).
          new(dependency: dependency, credentials: credentials)
      end

      def previous_version(dependency)
        if dependency.previous_version.match?(/^[0-9a-f]{40}$/)
          return previous_ref(dependency) if ref_changed?(dependency)
          dependency.previous_version[0..5]
        else
          dependency.previous_version
        end
      end

      def new_version(dependency)
        if dependency.version.match?(/^[0-9a-f]{40}$/)
          return new_ref(dependency) if ref_changed?(dependency)
          dependency.version[0..5]
        else
          dependency.version
        end
      end

      def previous_ref(dependency)
        dependency.previous_requirements.map do |r|
          r.dig(:source, "ref") || r.dig(:source, :ref)
        end.compact.first
      end

      def new_ref(dependency)
        dependency.requirements.map do |r|
          r.dig(:source, "ref") || r.dig(:source, :ref)
        end.compact.first
      end

      def new_library_requirement(dependency)
        updated_reqs =
          dependency.requirements - dependency.previous_requirements

        gemspec =
          updated_reqs.find { |r| r[:file].match?(%r{^[^/]*\.gemspec$}) }
        return gemspec[:requirement] if gemspec
        updated_reqs.first[:requirement]
      end

      def ref_changed?(dependency)
        previous_ref(dependency) && new_ref(dependency) &&
          previous_ref(dependency) != new_ref(dependency)
      end

      def library?
        filenames = files.map(&:name)
        return true if filenames.any? { |nm| nm.match?(%r{^[^/]*\.gemspec$}) }
        dependencies.none?(&:appears_in_lockfile?)
      end

      def switching_from_ref_to_release?(dependency)
        return false unless dependency.previous_version.match?(/^[0-9a-f]{40}$/)
        Gem::Version.correct?(dependency.version)
      end

      def using_semantic_commit_messages?
        return false if recent_commit_messages.none?

        semantic_messages = recent_commit_messages.select do |message|
          SEMANTIC_PREFIXES.any? { |pre| message.match?(/#{pre}[:(]/i) }
        end

        semantic_messages.count.to_f / recent_commit_messages.count > 0.3
      end

      def recent_commit_messages
        @recent_commit_messages ||=
          github_client.commits(repo_name).
          reject { |c| c.author&.type == "Bot" }.
          map(&:commit).
          map(&:message).
          compact
      end

      def credentials
        [
          {
            "host" => "github.com",
            "username" => "x-access-token",
            "password" => github_client.access_token
          }
        ]
      end
    end
  end
end
