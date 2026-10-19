include $(TOPDIR)/rules.mk

PKG_NAME:=wrt-hotspot
PKG_VERSION:=0.7.0
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
	+ucode-mod-rtnl +ucode-mod-digest \
	+uhttpd +uhttpd-mod-ucode \
	+nftables-json +kmod-nft-nat +kmod-nft-fib +firewall4
endef

define Package/wrt-hotspot/description
  Captive portal hotspot for OpenWrt modelled on MikroTik Hotspot: local users,
  trial, MAC, cookie and CHAP/PAP/HTTPS logins, RADIUS with CoA, walled garden,
  per-user limits, scheduled limitations, accounting, MikroTik compatible login
  pages, and full dual-stack (IPv4 + IPv6) client handling. Without the
  wrt-hotspot-shaper package, rate limits use nftables policing. RADIUS is
  in wrt-hotspot-radius; without it the hotspot uses local users only.
endef

define Package/wrt-hotspot/conffiles
/etc/config/wrthotspot
/etc/wrthotspot/
endef

# Meta package: everything the tc HTB shaper needs (fq_codel is built in).
define Package/wrt-hotspot-shaper
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Captive Portals
  TITLE:=Per-user traffic shaping (tc HTB) for wrt-hotspot
  PKGARCH:=all
  DEPENDS:=+wrt-hotspot +tc-full +kmod-sched-core +kmod-sched +kmod-sched-flower +kmod-ifb
endef

define Package/wrt-hotspot-shaper/description
  Pulls in tc, HTB, flower, mirred and IFB so wrt-hotspot shapes each user
  with HTB + fq_codel (MikroTik rate-limit incl. burst, priority, limit-at)
  instead of policing with nftables.
endef

# RADIUS client, accounting and CoA/Disconnect listener. Optional so that
# small routers can run on local users with less flash and memory.
define Package/wrt-hotspot-radius
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Captive Portals
  TITLE:=RADIUS and billing-system integration for wrt-hotspot
  PKGARCH:=all
  DEPENDS:=+wrt-hotspot +ucode-mod-socket +ucode-mod-struct
endef

define Package/wrt-hotspot-radius/description
  RADIUS PAP/CHAP/MAC authentication, accounting with interim updates and
  gigawords, CoA and Disconnect-Request, MikroTik, WISPr, ChilliSpot and
  Ascend attributes, presets for third-party RADIUS / billing servers, and a
  RouterOS API subset (tcp/8728) for billing systems made for MikroTik.
endef

# Everything: core, RADIUS, shaping, LuCI app and operator panel.
define Package/wrt-hotspot-full
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Captive Portals
  TITLE:=WrtHotspot with all features
  PKGARCH:=all
  DEPENDS:=+wrt-hotspot +wrt-hotspot-radius +wrt-hotspot-shaper +wrt-hotspot-panel +luci-app-wrt-hotspot
endef

define Build/Compile
endef

define Package/wrt-hotspot/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/usr/sbin
	$(INSTALL_CONF) ./files/etc/config/wrthotspot $(1)/etc/config/wrthotspot
	$(INSTALL_BIN) ./files/etc/init.d/wrthotspot $(1)/etc/init.d/wrthotspot
	$(INSTALL_DIR) $(1)/etc/sysctl.d
	$(INSTALL_DATA) ./files/etc/sysctl.d/12-wrthotspot.conf $(1)/etc/sysctl.d/
	$(INSTALL_BIN) ./files/usr/sbin/hotspotd $(1)/usr/sbin/hotspotd
	$(INSTALL_BIN) ./files/usr/sbin/wrthotspot $(1)/usr/sbin/wrthotspot
	$(INSTALL_DIR) $(1)/usr/share/ucode/wrthotspot
	$(INSTALL_DATA) $(filter-out %/radius.uc %/rosapi.uc,$(wildcard ./files/usr/share/ucode/wrthotspot/*.uc)) \
		$(1)/usr/share/ucode/wrthotspot/
	$(INSTALL_DIR) $(1)/usr/share/wrthotspot/pages/default
	$(INSTALL_DATA) ./files/usr/share/wrthotspot/portal.uc $(1)/usr/share/wrthotspot/
	$(INSTALL_DATA) ./files/usr/share/wrthotspot/pages/default/* $(1)/usr/share/wrthotspot/pages/default/
endef

define Package/wrt-hotspot-radius/install
	$(INSTALL_DIR) $(1)/usr/share/ucode/wrthotspot
	$(INSTALL_DATA) ./files/usr/share/ucode/wrthotspot/radius.uc ./files/usr/share/ucode/wrthotspot/rosapi.uc $(1)/usr/share/ucode/wrthotspot/
endef

# hotspotd loads RADIUS support at start.
define Package/wrt-hotspot-radius/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/wrthotspot restart 2>/dev/null
exit 0
endef

define Package/wrt-hotspot-radius/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/wrthotspot restart 2>/dev/null
exit 0
endef

define Package/wrt-hotspot-shaper/install
	true
endef

define Package/wrt-hotspot-full/install
	true
endef

$(eval $(call BuildPackage,wrt-hotspot))
$(eval $(call BuildPackage,wrt-hotspot-radius))
$(eval $(call BuildPackage,wrt-hotspot-shaper))
$(eval $(call BuildPackage,wrt-hotspot-full))
