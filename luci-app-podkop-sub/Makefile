include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-podkop-sub

PKG_VERSION := $(if $(PODKOP_SUB_VERSION),$(PODKOP_SUB_VERSION),0.$(shell date +%d%m%Y))

PKG_RELEASE:=1

# luci.mk would derive the i18n version from git, giving it a date-stamped one of its own;
# pin it so luci-i18n-podkop-sub-ru carries exactly the version of the package it translates
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)

LUCI_TITLE:=Subscriptions for podkop
LUCI_DEPENDS:=+luci-base +podkop
LUCI_PKGARCH:=all
LUCI_URL:=https://github.com/witpurge/Podkop-subscription-plugin
LUCI_LANG.ru:=Русский (Russian)
LUCI_LANG.en:=English

PKG_LICENSE:=AGPL-3.0-only
# luci.mk reads LUCI_MAINTAINER, not PKG_MAINTAINER
LUCI_MAINTAINER:=witpurge <dev@witpurge.invalid>

# LUCI_LANGUAGES is not ours to set: luci.mk derives it from po/* and builds the i18n packages

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/podkop-sub
endef

# No postinst here: luci.mk defines one under ifndef and ours would replace it

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/podkop-sub stop 2>/dev/null
/etc/init.d/podkop-sub disable 2>/dev/null
/usr/bin/podkop-sub restore 2>/dev/null
rm -f /tmp/luci-indexcache*
exit 0
endef

# opkg and apk remove files but not the directories they left empty
define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rmdir /usr/share/podkop-sub/lib /usr/share/podkop-sub \
	/www/luci-static/resources/view/podkop-sub 2>/dev/null
exit 0
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)$(HTDOCS)
	$(CP) $(PKG_BUILD_DIR)/htdocs/* $(1)$(HTDOCS)/
	$(INSTALL_DIR) $(1)/
	$(CP) $(PKG_BUILD_DIR)/root/* $(1)/
	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PKG_VERSION)/g' $(1)/usr/share/podkop-sub/version
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
