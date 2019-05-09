##
## Simple Message Peer-to-Peer (SMPP) system_type based routing and bind management
##
## @version = 3
## @date = 22 Aug 2018
## @author = Vernon Wells (vwells@f5.com)
##
## This iRule facilitates routing SMPP v3.4 messages.  It assumes that:
##   1. all SMSCs are in a single pool
##   2. all ESMEs connect as dynamic peers
##   3. all binds are transceiver type
##   4. each SMSC and ESME connects with a single bound session
## When all ESMEs disconnect, all SMSCs must be unbound (and the associated transports must be
## closed).  Conversely, when all SMSCs disconnect, all ESMEs must be unbound.
##
## There is an associated iRule attached to another Virtual Server that is used for signaling
## from the control plane.  It is referred to here as the "internal message virtual server".
##
## The following session table entries are used in this rule:
##    - smpp-bound-esme-count
##    - smpp-bound-smsc-count
## These are both 'incr' type entries, and provide a count of the number of EMSEs (for the
## first table set) and SMSCs (for the second table set) that are currently bound.
## In addition, this sub-table contains a list of client-side (esme) peers by peer name.
## The value for each is the virtual through which it is connected.
##    - smpp-bound-esme-list
##
## The following data-group is referenced in RULE_INIT:
##    - static::smpp_config_elements_dg
## It has these keys:
##    - smsc-pool-name                : name of the SMSC pool
##    - smsc-transport-config-name    : name of the transport config used toward SMSC pool. Must include partition (e.g., /Common/tc01)
##    - bigip-system-id               : system_id for this BIGIP (must be no longer than 15 characters!)
##    - bigip-system-id-password      : the password used by the BIGIP when it binds to an SMSC
##    - asserted-system-type          : system_type asserted toward SMSCs by BIGIP
##
## Variables on the client-side flows include:
##   - proxy_side                  : the literal "client"
##   - incoming_buf                : a spooling buffer of incoming TCP data that has not yet been
##                                   handled as a PDU
##   - command_length              : command length field extracted from last incoming PDU
##   - command_id                  : command id field extracted from last incoming PDU (as unsigned value)
##   - command_status              : command status field extracted from last incoming PDU
##   - sequence_number             : sequence number field extracted from last incoming PDU
##   - is_request_msg              : if the last received message is a request message, set to non-zero; otherwise 0
##   - client_close_guard          : "guard" variable to ensure CLIENT_CLOSED procedures only happen once per flow
##                                 : (see comments in CLIENT_CLOSED)
##   - peer_state                  : the bind state of the peer, must be "waiting_for_bind" or "bound"
##   - peer_name                   : the name of this peer, except in the _EGRESS events, in which case, it is the reverse side peer_name
##   - my_vs_or_tc_name            : name of the Virtual Server for the client connection
##   - my_vs_or_tc_type            : the literal "virtual"
##   - local_seq_number            : a sequence number for egress rewriting local to this virtual server.  This
##                                   is the last sequence number used
##   - seq_rewrite_table           : associative array, indexed by "$proxy_side-$rewritten_seq_num", value is
##                                   list of { $original_seq_num $server_peer_name "config" $server_transport_config_name }
##                                   There is no timeout method for this.  It is removed when a matching
##                                   response comes back, or is overwritten on counter wrap (at 2**32-1)
##
## Variables on the server-side flows include:
##   - proxy_side                  : the literal "client"
##   - queued_messages             : a list of messages queued while waiting for bind procedure completion
##   - peer_state                  : the bind state of the peer, must be "waiting_for_bind_resp" or "bound"
##   - peer_name                   : the name of this peer, except in the _EGRESS events, in which case, it is the reverse side peer_name
##   - my_vs_or_tc_name            : name of the transport-config object for this serversise connection
##   - my_vs_or_tc_type            : the literal "config"
##   - incoming_buf                : a spooling buffer of incoming TCP data that has not yet been
##                                   handled as a PDU
##   - local_seq_number            : a sequence number for egress rewriting local to this transport.  This
##                                   is the last sequence number used
##   - seq_rewrite_table           : associative array, indexed by "$proxy_side-$rewritten_seq_num", value is
##                                   list of { $original_seq_num $peer_name "virtual" $client_vs_name }
##                                   There is no timeout method for this.  It is removed when a matching
##                                   response comes back, or is overwritten on counter wrap (at 2**32-1)
##   - my_system_id                : system_id asserted on bind
##   - password                    : password asserted on bind
##   - system_type                 : system_type asserted on bind
##   - command_length              : command length field extracted from last incoming PDU
##   - command_id                  : command id field extracted from last incoming PDU (as unsigned value)
##   - command_status              : command status field extracted from last incoming PDU
##   - sequence_number             : sequence number field extracted from last incoming PDU
##   - is_request_msg              : if the last received message is a request message, set to non-zero; otherwise 0
##   - route_select_counter        : a counter used to facilitate custom routing toward clientside, it is a modulo counter
##


proc smpp_log_debug {msg} {
    if { [clientside] } {
        log local0.debug "(clientside) $msg"
    } else {
        log local0.debug "(serverside) $msg"
    }
}

when RULE_INIT {
    set static::smpp_config_elements_dg "smpp-config-elements"

    array set static::smpp_command_map [list 1 bind_receiver 2 bind_transmitter 3 query_sm 4 submit_sm 5 deliver_sm 6 unbind 7 replace_sm 8 cancel_sm 9 bind_transceiver 11 outbind 21 enquire_link 33 submit_multi 259 data_sm 2147483648 generic_nack 2147483649 bind_receiver_resp 2147483650 bind_transmitter_resp 2147483651 query_sm_resp 2147483652 submit_sm_resp 2147483653 deliver_sm_resp 2147483654 unbind_resp 2147483655 replace_sm_resp 2147483656 cancel_sm_resp 2147483657 bind_transceiver_resp 2147483669 enquire_link_resp 2147483681 submit_multi_resp 2147483906 alert_notification 2147483907 data_sm_resp]
}

when CLIENT_ACCEPTED {
    set proxy_side "clientside"
    set peer_state "waiting_for_bind"
    set incoming_buf ""

    set local_seq_number 1      ;# 1 is reserved for bind message, so start at 2
    array set seq_rewrite_table [list]

    set peer_name "[IP::client_addr]:[TCP::client_port]"
    set my_vs_or_tc_name [virtual]
    set my_vs_or_tc_type "virtual"

    call smpp_log_debug "peer_name = ($peer_name); my_vs_or_tc_name = ($my_vs_or_tc_name); my_vs_or_tc_type = ($my_vs_or_tc_type)"

    GENERICMESSAGE::peer name $peer_name

    TCP::collect
}

when CLIENT_DATA {
    append incoming_buf [TCP::payload]

    TCP::release
    TCP::collect

    # Need at least 16 octets for a header, and thus, at least 16 octets for a PDU
    if { [string length $incoming_buf] >= 16 } {
        binary scan $incoming_buf IIII command_length command_id command_status sequence_number

        # convert $command_id to its unsigned value
        set command_id [expr { $command_id & 0xffffffff }]

        if { ($command_id & 0x80000000) == 0 } {
            set is_request_msg 1
        } else {
            set is_request_msg 0
        }

        call smpp_log_debug "is_request_msg = ($is_request_msg); command_length = ($command_length); command_id = ($command_id); command_name = ($static::smpp_command_map($command_id)); command_status = ($command_status); sequence_number = ($sequence_number)" 

        if { $command_length > [string length $incoming_buf] } {
            # not enough octets in collected buf for length of next PDU, so its an incomplete PDU
            call smpp_log_debug "Not enough octets yet collected for complete PDU"  
            return
        }

        switch $command_id {
            1 - 2 - 9 {                             ;# bind_* command
                call smpp_log_debug "Received bind_* command"  

                if { $peer_state eq "waiting_for_bind" } {
                    # send bind response
                    set resp_command_id [expr { 0x80000000 | $command_id }]

                    set my_system_id [class lookup "bigip-system-id" $static::smpp_config_elements_dg]

                    # +1 is for null octet after system_id
                    set response_message_length [expr { 16 + [string length $my_system_id] + 1 }]

                    call smpp_log_debug "resp_command_id = ($resp_command_id); resp_command_name = (command_name = ($static::smpp_command_map($resp_command_id)); my_system_id = ($my_system_id)"     

                    if { [table incr "smpp-bound-esme-count"] == 1 } {
                        # these connections may be (potentially very) long lived, so we
                        # don't use timer management for this entry
                        table set lifetime "smpp-bound-esme-count" indef
                        table set timeout "smpp-bound-esme-count" indef
                    }

                    table set -subtable "smpp-bound-esme-list" $peer_name [virtual] indef indef

                    call smpp_log_debug "Priming config = ([class lookup "smsc-transport-config-name" $static::smpp_config_elements_dg]), pool = ([class lookup "smsc-pool-name" $static::smpp_config_elements_dg])"       
                    MR::prime config [class lookup "smsc-transport-config-name" $static::smpp_config_elements_dg] pool [class lookup "smsc-pool-name" $static::smpp_config_elements_dg]

                    call smpp_log_debug "Responding to client with bind response"      
                    TCP::respond [binary format IIIIa*x $response_message_length $resp_command_id 0 $sequence_number $my_system_id]

                    set peer_state "bound"
                }
                else {
                    #send_error_message()
                }
            }

            2147483649 - 2147483650 - 2147483657 {  ;# bind_*_resp command
                log local0. "Received bind resp from peer ($peer_name).  Ignoring."  ;# T=I
            }

            6 {                                     ;# unbind command
                log local0. "Received unbind request from peer ($peer_name).  Sending unbind_resp and closing transport."     ;# T=I
                TCP::respond [binary format IIII 16 0x80000006 0 $sequence_number]
                TCP::close
                return
            }

            2147483654 {                            ;# unbind_resp command
                log local0. "Received unbind response from peer ($peer_name).  Closing transport."     ;# T=I
                TCP::close
            }

            21 {                                    ;# enquire_link command
                call smpp_log_debug "Received enquire_link from peer ($peer_name).  Sending response."    
                TCP::respond [binary format IIII 16 0x80000015 0 $sequence_number]
            }

            2147483669 {                            ;# enquire_link_resp command
                call smpp_log_debug "Received enquire_link response from peer ($peer_name).  Ignoring."
                # ignore the message
            }

            default {
                call smpp_log_debug "Routing message to serverside"
                GENERICMESSAGE::message create [string range $incoming_buf 0 [expr { $command_length - 1 }]]
            }
        }

        # remove current PDU from incoming buffer
        set incoming_buf [string range $incoming_buf $command_length end]
    }
}


when CLIENT_CLOSED {
    # Table commands can set aside flow handling, causing the reaper to later try to re-close
    # This can cause CLIENT_CLOSED to run more than once for the same flow.  We only want to
    # decrement the bind counting table by one, so put use a guard variable to ensure that we
    # only perform the following steps once on this flow
    if { ![info exists client_close_guard] } {
        set client_close_guard 1

        set binds [table incr "smpp-bound-esme-count" -1]

        if { $binds < 0 } {
            log local0.warn "WARNING: Bound ESME count is less than zero (usigned count is $binds)."  
            # we cannot precisely get out of this situation because 'table set' is not atomic, but we'll try,
            # knowing that the count may have changed between the time we did the previous 'table incr' and
            # when we do this
            table set "smpp-bound-esme-count" 0
            table delete -subtable "smpp-bound-esme-list" $peer_name
        }
        elseif { $binds == 0 } {
            table delete -subtable "smpp-bound-esme-list" $peer_name
            log local0. "All smpp dynamic peers disconnected"
        }
        else {                                                      ;# T=I
            log local0. "Remaining bound ESMEs is ($binds)"         ;# T=I
        }                                                           ;# T=I
    }
}



when SERVER_CONNECTED {
    set proxy_side "serverside"
    set peer_name "[IP::server_addr]:[TCP::server_port]"
    set my_vs_or_tc_name [lindex [split [MR::transport]] 1]
    set my_vs_or_tc_type "config"

    GENERICMESSAGE::peer name $peer_name

    call smpp_log_debug "peer_name = ($peer_name); my_vs_or_tc_name = ($my_vs_or_tc_name); my_vs_or_tc_type = ($my_vs_or_tc_type)"

    set queued_messages [list]

    set incoming_buf ""
    set local_seq_number 1      ;# 1 is reserved for bind message, so start at 2
    array set seq_rewrite_table [list]

    set route_select_counter 0

    set my_system_id [class lookup "bigip-system-id" $static::smpp_config_elements_dg]
    set password [class lookup "bigip-system-id-password" $static::smpp_config_elements_dg]
    set system_type [class lookup "asserted-system-type" $static::smpp_config_elements_dg]

    set response_cmd_length [expr { 16 + [string length $my_system_id] + 1 + [string length $password] + 1 + [string length $system_type] + 1 + 4 }]

    call smpp_log_debug "peer_name = ($peer_name); system_type = ($system_type), password = ($password), my_system_id = ($my_system_id), response_cmd_length = ($response_cmd_length)"

    call smpp_log_debug "Sending bind_transceiver"
    TCP::respond [binary format IIIIa*xa*xa*xcccc $response_cmd_length 9 0 1 $my_system_id $password $system_type 0x34 0 0 0]

    set peer_state "waiting_for_bind_resp"

    call smpp_log_debug "Setting count smpp-bound-smsc-count"

    if { [table incr "smpp-bound-smsc-count"] == 1 } {
        # these connections may be (potentially very) long lived, so we
        # don't use timer management for this entry
        table set lifetime "smpp-bound-smsc-count" indef
        table set timeout "smpp-bound-smsc-count" indef
    }

    set server_close_guard 0

    TCP::collect
}


when SERVER_DATA {
    append incoming_buf [TCP::payload]

    TCP::release
    TCP::collect

    # need at least 16 octets for a header, and thus, at least 16 octets for a PDU
    if { [string length $incoming_buf] >= 16 } {
        binary scan $incoming_buf IIII command_length command_id command_status sequence_number

        set command_length [expr { $command_length & 0xffffffff }]

        if { $command_length > [string length $incoming_buf] } {
            # not enough octets in collected buf for length of next PDU, so its and incomplete PDU
            return
        }

        # convert $command_id to its unsigned value
        set command_id [expr { $command_id & 0xffffffff }]

        if { ($command_id & 0x80000000) == 0 } {
            set is_request_msg 1
        } else {
            set is_request_msg 0
        }

        call smpp_log_debug "is_request_msg = ($is_request_msg); command_length = ($command_length), command_id = ($command_id), command_name = ($static::smpp_command_map($command_id)), command_status = ($command_status), sequence_number = ($sequence_number)"

        switch $command_id {
            1 - 2 - 9 {                             ;# bind_* command
                log local0. "Received unexpected bind command from SMSC peer ([IP::server_addr]:[TCP::server_port]).  Ignoring."
            }

            2147483649 - 2147483650 - 2147483657 {  ;# bind_*_resp command
                if { $peer_state eq "waiting_for_bind_resp" } {
                    set peer_state "bound"

                    call smpp_log_debug "Received bind response"
                    foreach m $queued_messages {
                        call smpp_log_debug "Sending queued message"
                        TCP::respond $m
                    }
                }
                #else {
                #    send_error_message()
                #}
            }

            6 {                                     ;# unbind command
                log local0. "Received unbind request from peer ([IP::server_addr]:[TCP::server_port]).  Sending unbind_resp and closing transport."     ;# T=I
                TCP::respond [binary format IIII 16 0x80000006 0 $sequence_number]
                TCP::close
                return
            }

            2147483654 {                            ;# unbind_resp command
                # assume that we sent an unbind command
                TCP::close
            }

            21 {                                    ;# enquire_link command
                call smpp_log_debug "Received enquire_link from peer ([IP::server_addr]:[TCP::server_port]).  Sending response."
                TCP::respond [binary format IIII 16 0x80000015 0 $sequence_number]
            }

            2147483669 {                            ;# enquire_link_resp command
                call smpp_log_debug "Received enquire_link response from peer ([IP::server_addr]:[TCP::server_port])."
                ;# ignore the message
            }

            default {
                call smpp_log_debug "Received message from peer"
                GENERICMESSAGE::message create [string range $incoming_buf 0 [expr { $command_length - 1 }]]
            }
        }

        # remove current PDU from incoming buffer
        set incoming_buf [string range $incoming_buf $command_length end]
    }

}


when SERVER_CLOSED {
    # Table commands can set aside flow handling, causing the reaper to later try to re-close
    # This can cause SERVER_CLOSED to run more than once for the same flow.  We only want to
    # decrement the bind counting table by one, so put use a guard variable to ensure that we
    # only perform the following steps once on this flow

    # This appears to be a bug.  SERVER_CLOSED fires multiple times, but on subsequent times
    # after the first, the Tcl context for the flow is gone.
    if { [info exists server_close_guard] } {
        call smpp_log_debug "Inside SERVER_CLOSED guard for [IP::server_addr]:[TCP::server_port]"

        set binds [table incr "smpp-bound-smsc-count" -1]

        if { $binds < 0 } {
            log local0.warn "WARNING: Bound SMSC count is less than zero (unsigned count is $binds)."  
            # we cannot precisely get out of this situation because 'table set' is not atomic, but we'll try,
            # knowing that the count may have changed between the time we did the previous 'table incr' and
            # when we do this one
            table set "smpp-bound-smsc-count" 0
        }
        elseif { $binds == 0 } {
            log local0. "All smpp static peers disconnected"
        }
        else {                                                      ;# T=I
            log local0. "Remaining bound SMSCs is ($binds)"         ;# T=I
        }                                                           ;# T=I
    }
}


when GENERICMESSAGE_INGRESS {
    if { !$is_request_msg } {
        call smpp_log_debug "GENERICMESSAGE_INGRESS for response message"

        #binary scan [GENERICMESSAGE::message data] IIIIc* im_command_length im_command_id im_command_status im_sequence_number im_body
        #set im_sequence_number [expr { $im_sequence_number & 0xffffffff }]
        set sequence_number [expr { $sequence_number & 0xffffffff }]

        call smpp_log_debug "command_length = ($command_length), command_id = ($command_id), command_name = ($static::smpp_command_map($command_id)), command_status = ($command_status), sequence_number = ($sequence_number)"

        call smpp_log_debug "Attempting sequence rewrite table lookup for key ($proxy_side-$sequence_number)"
        if { [info exists seq_rewrite_table("$proxy_side-$sequence_number")] } {
            set seq_based_route_info $seq_rewrite_table("$proxy_side-$sequence_number")

            call smpp_log_debug "seq_based_route_info = ($seq_based_route_info)"
            call smpp_log_debug "Altering sequence number back to original value: ([lindex $seq_based_route_info 0])"

            binary scan [GENERICMESSAGE::message data] x16c* im_body

            GENERICMESSAGE::message data [binary format IIIIc* $command_length $command_id $command_status [lindex $seq_based_route_info 0] $im_body]

            unset seq_rewrite_table("$proxy_side-$sequence_number")
        }
        else {
            log local0. "No matching sequence number rewrite found"     ;# T=I
        }
    }
}


when MR_INGRESS {
    set reverse_peer_name $peer_name
    set reverse_vs_or_tc_name $my_vs_or_tc_name
    set reverse_vs_or_tc_type $my_vs_or_tc_type

    MR::store reverse_peer_name reverse_vs_or_tc_name reverse_vs_or_tc_type

    if { $is_request_msg } {
        if { [serverside] } {
            call smpp_log_debug "serverside, requires custom routing"

            set bound_esme_list [table keys -subtable smpp-bound-esme-list]
            set bel_len [llength $bound_esme_list]

            call smpp_log_debug "bound_esme_list = ($bound_esme_list); bel_len = ($bel_len); last route_select_counter = ($route_select_counter)"

            if { $bel_len == 0 } {
                log local0.info "Received SMSC message but cannot deliver because no ESMEs are bound"
                MR::message drop
                return
            }

            set selected_esme [lindex $bound_esme_list [expr { [incr route_select_counter] % $bel_len }]]
            set selected_esme_virtual [table lookup -subtable smpp-bound-esme-list $selected_esme]

            call smpp_log_debug "Selected esme = ($selected_esme), virtual = ($selected_esme_virtual)"

            MR::message route virtual $selected_esme_virtual host $selected_esme
        }
    }
    elseif { [info exists seq_based_route_info] } {
        call smpp_log_debug "MR_INGRESS for response message"
        call smpp_log_debug "Re-routing to [lindex $seq_based_route_info 2] ([lindex $seq_based_route_info 3]) host ([lindex $seq_based_route_info 1])"
        MR::message route [lindex $seq_based_route_info 2] [lindex $seq_based_route_info 3] host [lindex $seq_based_route_info 1]
    }
}


when MR_EGRESS {
    MR::restore reverse_peer_name reverse_vs_or_tc_name reverse_vs_or_tc_type
    call smpp_log_debug "Restored Values: reverse_peer_name = ($reverse_peer_name), reverse_vs_or_tc_name = ($reverse_vs_or_tc_name), reverse_vs_or_tc_type = ($reverse_vs_or_tc_type)"
}


when GENERICMESSAGE_EGRESS {
    binary scan [GENERICMESSAGE::message data] IIII em_command_length em_command_id em_command_status em_sequence_number

    if { ($em_command_id & 0x80000000) == 0 } {
        call smpp_log_debug "GENERICMESSAGE_EGRESS message REQUEST"

        binary scan [GENERICMESSAGE::message data] x16c* em_body
        set rewritten_seq_num [expr { 0xffffffff & [incr local_seq_number] }]

        if { $rewritten_seq_num > 4294967295 } {
            set rewritten_seq_num 2
        }

        call smpp_log_debug "em_command_length = ($em_command_length), em_command_id = ($em_command_id), em_command_name = ($static::smpp_command_map($em_command_id)), em_command_status = ($em_command_status), em_sequence_number = ($em_sequence_number), rewritten_seq_num = ($rewritten_seq_num)"

        call smpp_log_debug "Writing information to sequence rewrite table for ($proxy_side-$rewritten_seq_num)"
        set seq_rewrite_table("$proxy_side-$rewritten_seq_num") [list $em_sequence_number $reverse_peer_name $reverse_vs_or_tc_type $reverse_vs_or_tc_name]

        if { [serverside] and $peer_state ne "bound" } {
            log local0. "Queueing message for delivery once bind is completed"      ;# T=I
            lappend queued_messages [binary format IIIIc* $em_command_length $em_command_id $em_command_status $rewritten_seq_num $em_body]
            GENERICMESSAGE::message drop
        }
        else {
            call smpp_log_debug "Delivering message with altered sequence number ($rewritten_seq_num)"
            TCP::respond [binary format IIIIc* $em_command_length $em_command_id $em_command_status $rewritten_seq_num $em_body]
        }
    }
    else {
        call smpp_log_debug "GENERICMESSAGE_EGRESS message REQUEST, sending directly"
        TCP::respond [GENERICMESSAGE::message data]
    }
}


when MR_FAILED {
    if { [clientside] } {
        if { [MR::message retry_count] >= [MR::max_retries] } {
            log local0. "Received dynamic-peer message that cannot be delivered after ([MR::max_retries]) retries."  ;# T=I
            MR::message drop
        }
        else {
            log local0. "Message send failed, retrying.  Status is [MR::message status]."
            MR::message nexthop none
            MR::retry
        }
    }
    else {
        log local0. "MR_FAILED for serverside incoming message: [MR::message status]"
    }
}
