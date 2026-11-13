# SPDX-License-Identifier: MIT
project('kita', 'c', version: '0.1.0', license: 'MIT',
  default_options: ['warning_level=1', 'c_std=gnu11'])

cc = meson.get_compiler('c')
wayland_client = dependency('wayland-client')
deps = [
  dependency('gio-2.0'),
  dependency('gio-unix-2.0'),
  wayland_client,
  dependency('libdrm'),
  dependency('cairo'),
  dependency('pangocairo'),
  cc.find_library('m'),
]

# The drm-lease protocol code, generated from wayland-protocols' own XML.
wl_protocols_dir = dependency('wayland-protocols', version: '>= 1.22').get_variable('pkgdatadir')
scanner = find_program(dependency('wayland-scanner', native: true).get_variable('wayland_scanner'))
xml = wl_protocols_dir / 'staging/drm-lease/drm-lease-v1.xml'
lease_h = custom_target('drm-lease-v1-client-protocol.h', input: xml,
  output: 'drm-lease-v1-client-protocol.h', command: [scanner, 'client-header', '@INPUT@', '@OUTPUT@'])
lease_c = custom_target('drm-lease-v1-protocol.c', input: xml,
  output: 'drm-lease-v1-protocol.c', command: [scanner, 'private-code', '@INPUT@', '@OUTPUT@'])

datadir = get_option('prefix') / get_option('datadir') / 'kita'
executable('kita', 'kita.c', lease_c, lease_h,
  c_args: '-DKITA_DATADIR="@0@"'.format(datadir),
  dependencies: deps, install: true)

# Bring-up probe: lease DSI-2 and modeset it, nothing else. Built, not installed.
executable('lease-modeset', 'lease-modeset.c', lease_c, lease_h,
  dependencies: [wayland_client, dependency('libdrm')])

install_data('data/dpms-main-on.qml', 'data/dpms-main-off.qml', install_dir: datadir)
install_data('data/kita.desktop', install_dir: get_option('sysconfdir') / 'xdg/autostart')
udevdir = dependency('udev').get_variable('udevdir')
install_data('data/82-kita-backlight.rules', 'data/82-kita-touch.rules',
  install_dir: udevdir / 'rules.d')
