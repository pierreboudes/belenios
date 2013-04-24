(** Compatibility layer with the Helios reference implementation *)

open Serializable_compat_t

val of_election : 'a election -> 'a Serializable_t.election
val of_ballot : 'a ballot -> 'a Serializable_t.ballot
val of_partial_decryption :
  'a partial_decryption -> 'a Serializable_t.partial_decryption
val of_result : 'a result -> 'a Serializable_t.result

module type COMPAT = sig
  type t
  val to_ballot : t Serializable_t.ballot -> t ballot
  val to_partial_decryption : t Serializable_t.ciphertext array array ->
    t Serializable_t.partial_decryption -> t partial_decryption
end

module MakeCompat (P : Crypto_sigs.ELECTION_PARAMS) :
  COMPAT with type t = P.G.t