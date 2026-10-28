"""Three checks of destination scoping; no route, VM or privileged operation."""
import base64
import unittest
from host_vpn import targets
from prepare import configs

class ConfigChecks(unittest.TestCase):
    def test_exact_targets_on_both_sides(self):
        server,client=configs(base64.b64encode(bytes(32)).decode(),['192.168.10.111','192.168.10.111'])
        self.assertEqual(client['inbounds'][0]['route_address'],['192.168.10.111/32'])
        self.assertEqual(server['route']['rules'][0]['ip_cidr'],['192.168.10.111/32'])
        self.assertEqual(server['route']['rules'][-1],{'action':'reject'})
        self.assertEqual(server['outbounds'][0]['bind_interface'],'LinkManager Adapter')
        self.assertEqual(client['inbounds'][0]['dns_mode'],'disabled')
    def test_no_default_or_broad_networks(self):
        for value in ['0.0.0.0','0.0.0.0/0','192.168.10.0/24','127.0.0.1','224.0.0.1','8.8.8.8']:
            with self.assertRaises(ValueError):targets([value])
    def test_no_empty_capture(self):
        with self.assertRaises(ValueError):targets([])

if __name__=='__main__':unittest.main()
