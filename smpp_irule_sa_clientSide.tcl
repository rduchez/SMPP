#
# This listener accepts text based messages and emits text based responses.
# Client (request) messages include:
#   PRIME all smscs                 : prime SMSCs for all system_types for which there is at least one bound ESME
#   UNBIND smscs                    : unbind all static peers (smscs in pool)
#   UNBIND esmes                    : unbind all dynamic peers (esmes in bind list)
#   SHOW bound esme count           : retrieve the number of bound esmes (result is "201 VALUE <n>")
#   SHOW bound smsc count           : retrieve the number of bound esmes (result is "201 VALUE <n>")
#   SHOW bound esme list            : retrieve a list of the bound esme peer ids (result is "201 VALUE <n>[,<n>[,...]]"
#   RESET                           : reset all internal tables to base values
#
# Server (response) message include:
#   200 OK                          : action completed as requested
#   400 CMD_NOT_UNDERSTOOD          : command not recognized
#   401 CMD_FORMAT_ERROR            : command recognized but the parameters are malformed
#   402 UNKNOWN_SYSTEM_TYPE         : the supplied system_type is not known
#   500 FAILED <msg>                : attempt failed, <msg> contains error
#
when CLIENT_ACCEPTED {
    log local0. "Received message on [virtual]"     ;# T=D

    GENERICMESSAGE::peer name "internal-msg-[IP::client_addr]:[TCP::client_port]"

    TCP::collect
}

when CLIENT_DATA {
    set payload [TCP::payload]

    switch $payload {
        "PRIME all smscs" {
            log local0. "Command is PRIME all smscs"    ;# T=D

            if { [catch { MR::prime config [class lookup "smsc-transport-config-name" $static::smpp_config_elements_dg] pool [class lookup "smsc-pool-name" $static::smpp_config_elements_dg] } errstr] } {
                TCP::respond "500 FAILED [join $errstr]"
                return
            }
            else {
                TCP::respond "200 OK"
                return
            }
        }

        "UNBIND smscs" {
            log local0. "Command is UNBIND smscs"     ;# T=D

            set unbind_target smscs
            foreach pm [active_members -list [class lookup "smsc-pool-name" $static::smpp_config_elements_dg]] {
                set pm [join $pm :]

                log local0. "Sending unbind to ($pm)"    ;# T=D

                GENERICMESSAGE::message create [binary format IIII 16 6 0 1] $pm
            }

            TCP::respond "200 OK"
        }

        "UNBIND esmes" {
            log local0. "Command is UNBIND esmes"       ;# T=D

            set unbind_targets esmes
            foreach esme [table keys -subtable "smpp-bound-esme-list"] {
                log local0. "Sending unbind to ($esme)" ;# T=D
                GENERICMESSAGE::message create [binary format IIII 16 6 0 1] $esme
            }

            TCP::respond "200 OK"
        }

        "SHOW bound esme count" {
            log local0. "Command is SHOW bound esme count"      ;# T=D

            set c [table lookup "smpp-bound-esme-count"]

            log local0. "Lookup value = ($c)"                   ;# T=D

            if { $c eq "" } { set c 0 }

            TCP::respond "201 VALUE $c"
        }

        "SHOW bound smsc count" {
            log local0. "Command is SHOW bound smsc count"      ;# T=D

            set c [table lookup "smpp-bound-smsc-count"]

            log local0. "Lookup value = ($c)"                   ;# T=D

            if { $c eq "" } { set c 0 }

            TCP::respond "201 VALUE $c"
        }

        "SHOW bound esme list" {
            log local0. "Command is SHOW bound esme list"       ;# T=D

            set l [table keys -subtable "smpp-bound-esme-list"]

            if { $l ne "" } {
                set l [join $l ,]
            }

            TCP::respond "201 VALUE $l"
        }

        "RESET" {
            log local0. "Command is RESET"                      ;# T=D

            table delete -subtable "smpp-bound-esme-list" -all
            table set "smpp-bound-esme-count" 0 indef indef
            table set "smpp-bound-smsc-count" 0 indef indef

            TCP::respond "200 OK"
        }

        default {
            TCP::respond "400 CMD_NOT_UNDERSTOOD"
        }
    }

    TCP::close
}



when CLIENT_CLOSED {
    log local0. "CLIENT_CLOSED"
}

when MR_FAILED {
    log local0. "MR_FAILED"
}
