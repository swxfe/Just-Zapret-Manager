import { run as domains } from './domains.uc';
import { run as github } from './github.uc';
import { run as packages } from './packages.uc';
import { run as strategies } from './strategies.uc';
import { run as sources } from './sources.uc';
import { run as applied_state } from './applied-state.uc';
import { run as devices } from './devices.uc';
import { run as files_settings } from './files-settings.uc';
import { checks } from '../support/assertions.uc';

domains();
github();
packages();
strategies();
sources();
applied_state();
devices();
files_settings();
printf('unit: %d checks passed\n', checks());
