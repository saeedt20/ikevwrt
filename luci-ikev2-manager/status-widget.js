// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Nikitid
'use strict';
'require baseclass';
'require fs';
'require ikev2-manager.shared-v23 as common';

// Shadow the global _() with the project translator for this module only;
// see the note in shared.js about not replacing window._.
var _ = common.t;

var helper = '/usr/libexec/ikev2-manager';
var swanmon = '/usr/sbin/swanmon';

function failed(response) {
	return !response || (response.code != null && Number(response.code) !== 0);
}

function findOutbound(sas) {
	for (var i = 0; i < sas.length; i++) {
		if (sas[i]['proxy-out'])
			return sas[i]['proxy-out'];
	}
	return null;
}

function installedChild(sa, name) {
	return Object.values((sa && sa['child-sas']) || {}).find(function(child) {
		return child.state === 'INSTALLED' && (!name || child.name === name);
	}) || null;
}


function traffic(direction, bytes, label) {
	return E('span', {
		'class': 'ikev2-traffic ' + direction,
		'title': label
	}, [
		common.icon(direction === 'received' ? 'down' : 'up'),
		E('span', {}, [
			E('span', { 'class': 'ikev2-traffic-label' }, [ direction === 'received' ? _('Downloaded') : _('Uploaded') ]),
			E('strong', {}, [ common.formatBytes(bytes) ])
		])
	]);
}


function componentCard(label, state, detail, meta) {
	return E('div', { 'class': 'ikev2-widget-component' }, [
		E('div', { 'class': 'ikev2-widget-component-head' }, [
			E('span', { 'class': 'ikev2-widget-component-label' }, [ label ]),
			common.pill(state.label, state.tone)
		]),
		detail ? E('div', { 'class': 'ikev2-widget-component-detail' }, detail) : '',
		meta ? E('div', { 'class': 'ikev2-widget-component-meta' }, meta) : ''
	]);
}

function outboundComponent(statusAvailable, status, sasAvailable, sas) {
	if (!statusAvailable) {
		return {
			issue: true,
			node: componentCard(_('Outbound tunnel'),
				{ label: _('Unavailable'), tone: 'bad' },
				[ _('Connection state is unavailable.') ])
		};
	}
	if (status.client_enabled !== '1') {
		return {
			issue: false,
			node: componentCard(_('Outbound tunnel'),
				{ label: _('Disabled'), tone: 'neutral' },
				[ _('Outbound client is disabled.') ])
		};
	}
	if (!sasAvailable) {
		return {
			issue: true,
			node: componentCard(_('Outbound tunnel'),
				{ label: _('Unavailable'), tone: 'bad' },
				[ _('Connection state is unavailable.') ])
		};
	}

	var outbound = findOutbound(sas);
	var child = outbound && outbound.state === 'ESTABLISHED' ?
		installedChild(outbound, 'proxy4') : null;
	if (!child) {
		return {
			issue: true,
			node: componentCard(_('Outbound tunnel'),
				{ label: _('Disconnected'), tone: 'bad' },
				[ _('No installed outbound CHILD_SA.') ])
		};
	}

	var interfacePresent = status.interface_present === '1';
	var down = Number(status.interface_bytes_in || 0);
	var up = Number(status.interface_bytes_out || 0);
	var counterAge = _('Since ipsec-out was created');
	return {
		issue: false,
		node: componentCard(_('Outbound tunnel'),
			{ label: _('Connected'), tone: 'good' },
			[ _('Online for %s').format(common.formatDuration(outbound.established)) ],
			interfacePresent ? [
				traffic('received', down, _('Downloaded') + ' · ' + counterAge),
				traffic('sent', up, _('Uploaded') + ' · ' + counterAge)
			] : [
				E('span', {}, [ _('ipsec-out is unavailable') ])
			])
	};
}

function policyComponent(statusAvailable, status) {
	if (!statusAvailable) {
		return {
			issue: true,
			node: componentCard(_('Policy routing'),
				{ label: _('Unavailable'), tone: 'bad' },
				[ _('Routing state is unavailable.') ])
		};
	}
	if (status.configured !== '1') {
		return {
			issue: false,
			node: componentCard(_('Policy routing'),
				{ label: _('Disabled'), tone: 'neutral' },
				[ _('Managed routing is disabled.') ])
		};
	}

	var pbrReady = status.pbr === 'running';
	var failClosed = status.killswitch === 'active';
	var fakeIp = status.domain_engine === 'fakeip';
	var reliable = fakeIp && status.domain_service === 'running' &&
		status.domain_healthy === 'yes';
	var state;

	if (!pbrReady)
		state = { label: _('PBR stopped'), tone: 'bad' };
	else if (!failClosed)
		state = { label: _('Fail-closed missing'), tone: 'bad' };
	else if (fakeIp && !reliable)
		state = { label: _('Reliable mode degraded'), tone: 'bad' };
	else if (fakeIp)
		state = { label: _('Reliable mode active'), tone: 'good' };
	else
		state = { label: _('Standard mode active'), tone: 'info' };

	var counts = [];
	if (Number(status.device_fullroute || 0))
		counts.push(_('%d full-route rules').format(Number(status.device_fullroute)));
	if (Number(status.pbr_domains || 0))
		counts.push(_('%d domains').format(Number(status.pbr_domains)));
	if (Number(status.community_services || 0))
		counts.push(_('%d service groups').format(Number(status.community_services)));
	var addressCount = Number(status.manual_addresses || 0);
	if (addressCount)
		counts.push(_('%d address rules').format(addressCount));
	var excludedDevices = Number(status.device_excluded || 0);
	if (excludedDevices)
		counts.push(_('%d excluded devices').format(excludedDevices));
	var bypasses = Number(status.device_dns_passthrough || 0) +
		Number(status.device_dpi_passthrough || 0);
	if (bypasses)
		counts.push(_('%d bypass settings').format(bypasses));
	var excludedTraffic = Number(status.device_excluded_bytes || 0);

	return {
		issue: !pbrReady || !failClosed || (fakeIp && !reliable),
		node: componentCard(_('Policy routing'), state,
			[ counts.join(' · ') || _('Device and destination policies') ], [
			E('span', {}, [
				pbrReady ? _('PBR running') : _('PBR stopped')
			]),
			E('span', {}, [
				failClosed ? _('Fail-closed active') : _('Fail-closed missing')
			]),
			excludedDevices ? E('span', {}, [
				_('Excluded traffic: %s').format(common.formatBytes(excludedTraffic))
			]) : ''
		])
	};
}


return baseclass.extend({
	title: 'IKEv2 Manager',

	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec(helper, [ 'widget-status' ]), {
				code: 1,
				stdout: ''
			}),
			L.resolveDefault(fs.exec(swanmon, [ 'list-sas' ]), {
				code: 1,
				stdout: ''
			})
		]);
	},

	render: function(data) {
		var statusAvailable = data && !failed(data[0]);
		var sasAvailable = data && !failed(data[1]);
		var status = statusAvailable ? common.parseKeyValues(data[0].stdout) : {};
		var sas = sasAvailable ? common.parseSwanmon(data[1]) : [];
		var outbound = outboundComponent(statusAvailable, status, sasAvailable, sas);
		var policy = policyComponent(statusAvailable, status);
		var projectState;

		if (!statusAvailable) {
			projectState = {
				label: _('Project status is unavailable.'),
				tone: 'bad'
			};
		}
		else if (status.configured !== '1') {
			projectState = {
				label: _('Not configured'),
				tone: 'neutral'
			};
		}
		else if (outbound.issue || policy.issue ||
				(status.client_enabled === '1' && status.health !== 'up')) {
			projectState = {
				label: _('Action required'),
				tone: 'bad'
			};
		}
		else {
			projectState = {
				label: _('Operational'),
				tone: 'good'
			};
		}


		return E('div', {}, [
			common.styles(),
			E('div', { 'class': 'ikev2-page ikev2-status-widget' }, [
				E('div', { 'class': 'ikev2-widget-summary' }, [
					common.pill(projectState.label, projectState.tone),
					E('a', {
						'class': 'ikev2-quick-link',
						'href': L.url('admin', 'services', 'ikev2-manager', 'setup')
					}, [ _('Open IKEv2 Manager') ])
				]),
				E('div', { 'class': 'ikev2-widget-overview' }, [ outbound.node, policy.node ])
			])
		]);
	}
});
