import { LegalView } from '../../src/components/LegalView';
import { PRIVACY } from '../../src/domain/legal';

export default function Privacy() {
  return <LegalView sections={PRIVACY} />;
}
