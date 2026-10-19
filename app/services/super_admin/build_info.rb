# frozen_string_literal: true

# Which build of OneLink is running: the commit it was built from (GIT_HASH, see config/initializers/git_sha.rb). The
# version a person reads is the short commit; the full one is the build. The open source base keeps its own version
# number (config/app.yml), which says nothing about what OneLink changed, so the pages do not show it.
module SuperAdmin::BuildInfo
  SHORT_LENGTH = 9
  UNKNOWN = 'unknown'

  module_function

  def known?
    GIT_HASH.present? && GIT_HASH != UNKNOWN
  end

  # «6833c23f1», or the Russian «не определена» when the build does not know its commit
  def version
    known? ? GIT_HASH[0, SHORT_LENGTH] : I18n.t('super_admin.build.unknown')
  end

  # The whole commit, or «не определена»
  def build
    known? ? GIT_HASH : I18n.t('super_admin.build.unknown')
  end
end
