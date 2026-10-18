include $(TOPDIR)/rules.mk

PKG_NAME:=wrt-hotspot-panel
PKG_VERSION:=0.7.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Usama Khan

include $(INCLUDE_DIR)/package.mk

define Package/wrt-hotspot-panel
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Captive Portals
  TITLE:=Operator panel for wrt-hotspot (vouchers, users, reports)
  PKGARCH:=all
  DEPENDS:=+wrt-hotspot +rpcd +uhttpd +uhttpd-mod-ubus
endef

define Package/wrt-hotspot-panel/description
  A standalone web panel for hotspot staff at http://<router>/hotspot/:
  voucher batches with printable templates, user management, live
  sessions, history and reports. Staff log in with their own operator
  accounts (rpcd logins with the operator or admin role) and have no
  access to the router's configuration.
endef

define Build/Compile
endef

define Package/wrt-hotspot-panel/install
	$(INSTALL_DIR) $(1)/www/hotspot $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/www/hotspot/* $(1)/www/hotspot/
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/wrthotspot-panel.json $(1)/usr/share/rpcd/acl.d/
endef

define Package/wrt-hotspot-panel/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/rpcd reload
endef

$(eval $(call BuildPackage,wrt-hotspot-panel))
