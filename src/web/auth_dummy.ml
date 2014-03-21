(**************************************************************************)
(*                                BELENIOS                                *)
(*                                                                        *)
(*  Copyright © 2012-2014 Inria                                           *)
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

open Web_signatures

type config = unit

let name = "dummy"

let parse_config ~instance ~attributes =
  match attributes with
  | [] -> ()
  | _ ->
    Printf.ksprintf failwith
      "invalid configuration for instance %s of auth/%s"
      instance name

module Make (N : NAME) (S : CONT_SERVICE) (T : TEMPLATES) : AUTH_INSTANCE = struct

  let service = Eliom_service.service
    ~path:N.path
    ~get_params:Eliom_parameter.unit
    ()

  let user_logout = (module S : CONT_SERVICE)

  let on_success_ref = Eliom_reference.eref
    ~scope:Eliom_common.default_session_scope
    (fun ~user_name ~user_logout -> Lwt.return ())

  let () = Eliom_registration.Html5.register ~service
    (fun () () ->
      let post_params = Eliom_parameter.(string "username") in
      let service = Eliom_service.post_coservice
        ~csrf_safe:true
        ~csrf_scope:Eliom_common.default_session_scope
        ~fallback:service
        ~post_params ()
      in
      let () = Eliom_registration.Redirection.register ~service
        ~scope:Eliom_common.default_session_scope
        (fun () user_name ->
          lwt on_success = Eliom_reference.get on_success_ref in
          on_success ~user_name ~user_logout >>
          S.cont ())
      in T.login_dummy ~service ()
    )

  let handler ~on_success () =
    Eliom_reference.set on_success_ref on_success >>
    Eliom_registration.Redirection.send service

end

let make () = (module Make : AUTH_SERVICE)

module A : AUTH_SYSTEM = struct
  type config = unit
  let name = name
  let parse_config = parse_config
  let make = make
end

let () = Auth_common.register_auth_system (module A : AUTH_SYSTEM)