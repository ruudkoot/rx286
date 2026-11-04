-- ============================================================================
-- rx286 - mame/rx286.lua
-- MAME's part of a test run on the IBM PC/AT (roadmap M9): COM2's null modem
-- set to receive at 115200 baud, the speed rx286's serial log runs at.
--
-- tools/run-test starts MAME with -autoboot_script pointing here.
-- ============================================================================

local ports = manager.machine.ioport.ports
local modem = ":isa3:comat:serport1:null_modem:"
local BAUD_115200 = 13
ports[modem .. "RS232_RXBAUD"].fields["RX Baud"].user_value = BAUD_115200
ports[modem .. "RS232_TXBAUD"].fields["TX Baud"].user_value = BAUD_115200
