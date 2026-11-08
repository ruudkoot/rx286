-- ============================================================================
-- rx286 - mame/rx286.lua
-- MAME's part of a test run on the IBM PC/AT (roadmap M9): COM2's null modem
-- set to receive at 115200 baud, the speed rx286's serial log runs at; and
-- the machine's end when the runner asks (os-server.md P15). MAME run so
-- takes no signal to stop, so once the transcript is done tools/run-test
-- makes the file RX286_MAME_STOP names, and the machine exits as MAME would
-- at its own end: its diskettes written back, at once.
--
-- tools/run-test starts MAME with -autoboot_script pointing here.
-- ============================================================================

local ports = manager.machine.ioport.ports
local modem = ":isa3:comat:serport1:null_modem:"
local BAUD_115200 = 13
ports[modem .. "RS232_RXBAUD"].fields["RX Baud"].user_value = BAUD_115200
ports[modem .. "RS232_TXBAUD"].fields["TX Baud"].user_value = BAUD_115200

local stop_file = os.getenv("RX286_MAME_STOP")

-- stop_asked - whether the runner has made the stop file
local function stop_asked()
    local f = stop_file and io.open(stop_file, "r")
    if f then
        f:close()
        return true
    end
    return false
end

-- periodic - once a frame: the machine's end, if asked
local function periodic()
    if stop_asked() then
        manager.machine:exit()
    end
end

if emu.add_machine_periodic_notifier then
    rx286_periodic = emu.add_machine_periodic_notifier(periodic)   -- kept: a subscription
else
    emu.register_periodic(periodic)
end
