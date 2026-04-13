#!/bin/bash
sed -i -e "s/\`BSV_ASSIGNMENT_DELAY//g" -e "/\`ifdef BSV_ASSIGNMENT_DELAY/,/\`endif/d" -e "s/#0;//g" "$@"
