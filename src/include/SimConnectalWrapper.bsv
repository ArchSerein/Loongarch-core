import Types::*;
import SimInterfaces::*;
import Tb::*;

module mkSimConnectalWrapper#(SimIndication indication)(SimConnectalWrapper);
  SimRequest coreReq <- mkTbCore(indication);
  interface request = coreReq;
endmodule

export mkSimConnectalWrapper;
export SimConnectalWrapper;
