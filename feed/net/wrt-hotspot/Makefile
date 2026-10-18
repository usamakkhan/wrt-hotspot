include $(TOPDIR)/rules.mk

PKG_NAME:=wrt-hotspot
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Usama Khan

include $(INCLUDE_DIR)/package.mk

define Package/wrt-hotspot
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Captive Portals
  TITLE:=MikroTik-class captive portal hotspot with IPv6
  PKGARCH:=all
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +ucode-mod-uloop \
	+ucode-mod-rtnl +ucode-mod-digest +uhttpd +uhttpd-mod-ucode \
	+nftables-json +kmod-nft-nat +kmod-nft-fib +firewall4
endef

define Package/wrt-hotspot/description
  Captive portal hotspot for OpenWrt modelled on MikroTik Hotspot: local users,
  trial, MAC and CHAP/PAP logins, per-user limits and accounting, MikroTik
  compatible login pages, and full dual-stack (IPv4 + IPv6) client handling.
endef

define Package/wrt-hotspot/conffiles
/etc/config/wrthotspot
/etc/wrthotspot/
endef

define Build/Compile
endef

define Package/wrt-hotspot/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/usr/sbin
	$(INSTALL_CONF) ./files/etc/config/wrthotspot $(1)/etc/config/wrthotspot
	$(INSTALL_BIN) ./files/etc/init.d/wrthotspot $(1)/etc/init.d/wrthotspot
	$(INSTALL_BIN) ./files/usr/sbin/hotspotd $(1)/usr/sbin/hotspotd
	$(INSTALL_BIN) ./files/usr/sbin/wrthotspot $(1)/usr/sbin/wrthotspot
	$(INSTALL_DIR) $(1)/usr/share/ucode/wrthotspot
	$(INSTALL_DATA) ./files/usr/share/ucode/wrthotspot/*.uc $(1)/usr/share/ucode/wrthotspot/
	$(INSTALL_DIR) $(1)/usr/share/wrthotspot/pages/default
	$(INSTALL_DATA) ./files/usr/share/wrthotspot/portal.uc $(1)/usr/share/wrthotspot/
	$(INSTALL_DATA) ./files/usr/share/wrthotspot/pages/default/* $(1)/usr/share/wrthotspot/pages/default/
endef

$(eval $(call BuildPackage,wrt-hotspot))
