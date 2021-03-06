(**************************************************************************)
(*                                BELENIOS                                *)
(*                                                                        *)
(*  Copyright © 2012-2018 Inria                                           *)
(*                                                                        *)
(*  This program is free software: you can redistribute it and/or modify  *)
(*  it under the terms of the GNU Affero General Public License as        *)
(*  published by the Free Software Foundation, either version 3 of the    *)
(*  License, or (at your option) any later version, with the additional   *)
(*  exemption that compiling, linking, and/or using OpenSSL is allowed.   *)
(*                                                                        *)
(*  This program is distributed in the hope that it will be useful, but   *)
(*  WITHOUT ANY WARRANTY; without even the implied warranty of            *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *)
(*  Affero General Public License for more details.                       *)
(*                                                                        *)
(*  You should have received a copy of the GNU Affero General Public      *)
(*  License along with this program.  If not, see                         *)
(*  <http://www.gnu.org/licenses/>.                                       *)
(**************************************************************************)

open Lwt
open Eliom_service
open Web_common

let next_lf str i =
  String.index_from_opt str i '\n'

let scope = Eliom_common.default_session_scope

let cas_server = Eliom_reference.eref ~scope None

let login_cas = Eliom_service.create
  ~path:(Eliom_service.Path ["auth"; "cas"])
  ~meth:(Eliom_service.Get Eliom_parameter.(opt (string "ticket")))
  ()

let cas_self =
  (* lazy so rewrite_prefix is called after server initialization *)
  lazy (Eliom_uri.make_string_uri
          ~absolute:true
          ~service:(preapply login_cas None)
          () |> rewrite_prefix)

let parse_cas_validation info =
  match next_lf info 0 with
  | Some i ->
     (match String.sub info 0 i with
     | "yes" -> `Yes
        (match next_lf info (i+1) with
        | Some j -> Some (String.sub info (i+1) (j-i-1))
        | None -> None)
     | "no" -> `No
     | _ -> `Error `Parsing)
  | None -> `Error `Parsing

let get_cas_validation server ticket =
  let url =
    let cas_validate = Eliom_service.extern
      ~prefix:server
      ~path:["validate"]
      ~meth:(Eliom_service.Get Eliom_parameter.(string "service" ** string "ticket"))
      ()
    in
    let service = preapply cas_validate (Lazy.force cas_self, ticket) in
    Eliom_uri.make_string_uri ~absolute:true ~service ()
  in
  let%lwt reply = Ocsigen_http_client.get_url url in
  match reply.Ocsigen_http_frame.frame_content with
  | Some stream ->
     let%lwt info = Ocsigen_stream.(string_of_stream 1000 (get stream)) in
     let%lwt () = Ocsigen_stream.finalize stream `Success in
     return (parse_cas_validation info)
  | None -> return (`Error `Http)

let cas_handler ticket () =
  Web_auth.run_post_login_handler "cas" (fun _ _ authenticate ->
      match ticket with
      | Some x ->
         let%lwt server =
           match%lwt Eliom_reference.get cas_server with
           | None -> failwith "cas handler was invoked without a server"
           | Some x -> return x
         in
         (match%lwt get_cas_validation server x with
          | `Yes (Some name) -> authenticate name
          | `No -> fail_http 401
          | `Yes None | `Error _ -> fail_http 502
         )
      | None -> Eliom_reference.unset cas_server
    )

let () = Eliom_registration.Any.register ~service:login_cas cas_handler

let cas_login_handler a =
  match List.assoc_opt "server" a.Web_serializable_t.auth_config with
  | Some server ->
     let%lwt () = Eliom_reference.set cas_server (Some server) in
     let cas_login = Eliom_service.extern
       ~prefix:server
       ~path:["login"]
       ~meth:(Eliom_service.Get Eliom_parameter.(string "service"))
       ()
     in
     let service = preapply cas_login (Lazy.force cas_self) in
     Eliom_registration.(Redirection.send (Redirection service))
  | _ -> failwith "cas_login_handler invoked with bad config"

let () = Web_auth.register_pre_login_handler "cas" cas_login_handler
