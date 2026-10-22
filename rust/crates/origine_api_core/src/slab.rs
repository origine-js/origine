//! A slab of values addressed by ids that are unique for the life of the slab.
//!
//! The low 32 bits of an id index a slot, the high 32 bits are the slot's generation, bumped each
//! time the slot is freed. A stale id (the value was taken, the slot reused) therefore never
//! reaches the newer value: `take` returns `None`. Insert, take and lookup are O(1) and do not
//! allocate once the slab has grown to its working size.

/// Values in slots, with generation-checked ids.
pub struct Slab<T> {
    slots: Vec<(u32, Option<T>)>,
    free: Vec<u32>,
}

impl<T> Default for Slab<T> {
    fn default() -> Slab<T> {
        Slab { slots: Vec::new(), free: Vec::new() }
    }
}

fn id_of(generation: u32, index: usize) -> u64 {
    (u64::from(generation) << 32) | index as u64
}

impl<T> Slab<T> {
    /// Stores `value` and returns its id.
    pub fn insert(&mut self, value: T) -> u64 {
        let index = match self.free.pop() {
            Some(index) => index as usize,
            None => {
                self.slots.push((0, None));
                self.slots.len() - 1
            }
        };
        assert!(u32::try_from(index).is_ok(), "fewer than 2^32 live values");
        let slot = &mut self.slots[index];
        slot.1 = Some(value);
        id_of(slot.0, index)
    }

    /// Removes the value `id` names; `None` if it was already taken (or never existed).
    pub fn take(&mut self, id: u64) -> Option<T> {
        let (generation, index) = ((id >> 32) as u32, (id & 0xffff_ffff) as usize);
        let slot = self.slots.get_mut(index).filter(|slot| slot.0 == generation)?;
        let value = slot.1.take()?;
        slot.0 = slot.0.wrapping_add(1);
        self.free.push(index as u32);
        Some(value)
    }

    /// Whether `id` names a live value.
    pub fn contains(&self, id: u64) -> bool {
        let (generation, index) = ((id >> 32) as u32, (id & 0xffff_ffff) as usize);
        self.slots.get(index).is_some_and(|slot| slot.0 == generation && slot.1.is_some())
    }

    /// Removes and returns every value for which `pred` holds.
    pub fn take_where(&mut self, pred: impl Fn(&T) -> bool) -> Vec<T> {
        let mut taken = Vec::new();
        for index in 0..self.slots.len() {
            if self.slots[index].1.as_ref().is_some_and(&pred) {
                taken.extend(self.take(id_of(self.slots[index].0, index)));
            }
        }
        taken
    }

    /// Removes every value, dropping it.
    pub fn clear(&mut self) {
        for index in 0..self.slots.len() {
            drop(self.take(id_of(self.slots[index].0, index)));
        }
    }

    /// Number of live values.
    pub fn len(&self) -> usize {
        self.slots.len() - self.free.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_taken_once() {
        let mut slab = Slab::default();
        let a = slab.insert("a");
        let b = slab.insert("b");
        assert_eq!(slab.len(), 2);
        assert_eq!(slab.take(a), Some("a"));
        assert_eq!(slab.take(a), None);
        assert!(!slab.contains(a) && slab.contains(b));
        assert_eq!(slab.len(), 1);
    }

    #[test]
    fn a_stale_id_never_reaches_the_value_that_reused_its_slot() {
        let mut slab = Slab::default();
        let old = slab.insert(1);
        assert_eq!(slab.take(old), Some(1));
        let new = slab.insert(2);
        assert_ne!(old, new);
        assert_eq!(slab.take(old), None, "the old id must not take the new value");
        assert_eq!(slab.take(new), Some(2));
    }

    #[test]
    fn take_where_and_clear() {
        let mut slab = Slab::default();
        let ids: Vec<u64> = (0..10).map(|i| slab.insert(i)).collect();
        let mut even = slab.take_where(|v| v % 2 == 0);
        even.sort_unstable();
        assert_eq!(even, [0, 2, 4, 6, 8]);
        assert_eq!(slab.len(), 5);
        assert!(slab.contains(ids[1]) && !slab.contains(ids[2]));
        slab.clear();
        assert!(slab.is_empty());
        assert_eq!(slab.take(ids[1]), None);
    }

    #[test]
    fn unknown_ids_are_none() {
        let mut slab: Slab<u8> = Slab::default();
        assert_eq!(slab.take(0), None);
        assert_eq!(slab.take(u64::MAX), None);
        assert!(!slab.contains(5));
    }
}
