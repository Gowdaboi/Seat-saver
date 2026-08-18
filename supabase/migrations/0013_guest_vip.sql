-- VIP holds are already a real workflow — host_assign_seats() exists partly
-- to place them — but "VIP" only ever lived in the guest's name or in the
-- host's head. This makes it a fact about the guest, so the seat board can
-- flag it when the host taps an occupied seat and sees who is sitting there.
--
-- Deliberately not adding a dietary column alongside it: a guest's dietary
-- choice is expressed by what they are served, and the menu already carries
-- veg/nonveg per dish. Storing it per guest as well would be a second source
-- of truth with nothing keeping the two in agreement.

alter table guests add column is_vip boolean not null default false;

-- Partial index: VIPs are a small minority of guests, and the only query
-- that cares is "show me the VIPs", never "show me the non-VIPs".
create index guests_is_vip_idx on guests (id) where is_vip;
