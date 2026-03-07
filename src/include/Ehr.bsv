import Vector::*;
import RWire::*;
import RevertingVirtualReg::*;

typedef Vector#(n, Reg#(t)) Ehr#(numeric type n, type t);

module mkEhr(t initVal, Ehr#(n, t) ifc) provisos(Bits#(t, tSz));
  Reg#(t) ehrReg <- mkReg(initVal);

  Vector#(n, RWire#(t)) wires <- replicateM(mkUnsafeRWire);

  Vector#(n, Reg#(Bool)) virtual_reg <-
  replicateM(mkRevertingVirtualReg(False));
  Vector#(n, RWire#(t)) ignored_wires <- replicateM(mkUnsafeRWire);

  Ehr#(n, t) ifc_to_return;

  (* fire_when_enabled *) // WILL_FIRE == CAN_FIRE
  (* no_implicit_conditions *) // CAN_FIRE == guard (True)
  rule canonicalize;
    t val = ehrReg;
    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      val = fromMaybe(val, wires[i].wget);
    end
    ehrReg <= val;
  endrule

  for (Integer i = 0; i < valueOf(n); i = i + 1) begin
    ifc_to_return[i] =
    (interface Reg;
      method Action _write(t x);
        wires[i].wset(x);

        t ignore = ehrReg;
        for (Integer j = 0; j < i; j = j + 1) begin
          ignore = fromMaybe(ignore, wires[j].wget);
        end

        ignored_wires[i].wset(ignore);

        virtual_reg[i] <= True;
      endmethod

      method t _read;
        t val = ehrReg;
        for (Integer j = 0; j < i; j = j + 1) begin
          val = fromMaybe(val, wires[j].wget);
        end

        for (Integer j = i; j < valueOf(n); j = j + 1) begin
          if (virtual_reg[j]) begin
            val = unpack(0);
          end
        end

        return val;
      endmethod
    endinterface);
end
return ifc_to_return;
endmodule

module mkEhrU(Ehr#(n, t)) provisos(Bits#(t, tSz));
  let m <- mkEhr(?);
  return m;
endmodule
