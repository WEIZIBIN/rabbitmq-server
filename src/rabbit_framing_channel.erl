%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2010 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2010 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_framing_channel).
-include("rabbit.hrl").

-export([start_link/0, process/2, shutdown/1]).

%% internal
-export([mainloop/1]).

%%--------------------------------------------------------------------

start_link() ->
    Parent = self(),
    {ok, proc_lib:spawn_link(
           fun () -> mainloop(rabbit_channel_sup:channel(Parent)) end)}.

process(Pid, Frame) ->
    Pid ! {frame, Frame},
    ok.

shutdown(Pid) ->
    Pid ! terminate,
    ok.

%%--------------------------------------------------------------------

read_frame(ChannelPid) ->
    receive
        {frame, Frame}         -> Frame;
        terminate              -> rabbit_channel:shutdown(ChannelPid),
                                  read_frame(ChannelPid);
        Msg                    -> exit({unexpected_message, Msg})
    end.

mainloop(ChannelPid) ->
    {method, MethodName, FieldsBin} = read_frame(ChannelPid),
    Method = rabbit_framing:decode_method_fields(MethodName, FieldsBin),
    case rabbit_framing:method_has_content(MethodName) of
        true  -> {ClassId, _MethodId} = rabbit_framing:method_id(MethodName),
                 rabbit_channel:do(ChannelPid, Method,
                                   collect_content(ChannelPid, ClassId));
        false -> rabbit_channel:do(ChannelPid, Method)
    end,
    ?MODULE:mainloop(ChannelPid).

collect_content(ChannelPid, ClassId) ->
    case read_frame(ChannelPid) of
        {content_header, ClassId, 0, BodySize, PropertiesBin} ->
            Payload = collect_content_payload(ChannelPid, BodySize, []),
            #content{class_id = ClassId,
                     properties = none,
                     properties_bin = PropertiesBin,
                     payload_fragments_rev = Payload};
        {content_header, HeaderClassId, 0, _BodySize, _PropertiesBin} ->
            rabbit_misc:protocol_error(
              command_invalid,
              "expected content header for class ~w, "
              "got one for class ~w instead",
              [ClassId, HeaderClassId]);
        _ ->
            rabbit_misc:protocol_error(
              command_invalid,
              "expected content header for class ~w, "
              "got non content header frame instead",
              [ClassId])
    end.

collect_content_payload(_ChannelPid, 0, Acc) ->
    Acc;
collect_content_payload(ChannelPid, RemainingByteCount, Acc) ->
    case read_frame(ChannelPid) of
        {content_body, FragmentBin} ->
            collect_content_payload(ChannelPid,
                                    RemainingByteCount - size(FragmentBin),
                                    [FragmentBin | Acc]);
        _ ->
            rabbit_misc:protocol_error(
              command_invalid,
              "expected content body, got non content body frame instead",
              [])
    end.
