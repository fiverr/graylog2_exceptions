module Fiverr
  class BacktraceCleaner < ActiveSupport::BacktraceCleaner
    APP_DIRS_PATTERN        = /^\/?(app|config|lib|test)/
    FIVERR_GEMS_PATTERN     = /.*bundler\/gems/
    RENDER_TEMPLATE_PATTERN = /:in `_render_template_\w*'/

    def initialize
      super
      add_filter   { |line| line.sub("#{Rails.root}/", '') } if defined? Rails
      add_filter   { |line| line.sub(RENDER_TEMPLATE_PATTERN, '') }
      add_filter   { |line| line.sub('./', '/') } # for tests

      add_gem_filters
      if defined? $service_name_str
        add_silencer { |line| line !~ APP_DIRS_PATTERN  && line !~ FIVERR_GEMS_PATTERN && line !~ /.*#{$service_name_str}.*\/(service|worker)/}
      else
        add_silencer { |line| line !~ APP_DIRS_PATTERN  && line !~ FIVERR_GEMS_PATTERN}
      end

    end
    private
      def add_gem_filters
        gems_paths = (Gem.path | [Gem.default_dir]).map { |p| Regexp.escape(p) }
        return if gems_paths.empty?

        gems_regexp = %r{(#{gems_paths.join('|')})/gems/([^/]+)-([\w.]+)/(.*)}
        add_filter { |line| line.sub(gems_regexp, '\2 (\3) \4') }
      end
  end
end